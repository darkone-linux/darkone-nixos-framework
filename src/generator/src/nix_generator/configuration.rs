//! Top-level loader: turns the merged YAML config into a fully-populated
//! [`Configuration`] (users, hosts, zones, services, DNS records).
//!
//! The structure mirrors the original PHP `Configuration` class:
//! 1. parse + deep-merge `usr/config.yaml` and `var/generated/config.yaml`
//! 2. load network defaults
//! 3. load zones (and their `extraHosts`)
//! 4. load users (regular + special `nix` maintenance user)
//! 5. load hosts in three flavours — static, range, list
//! 6. propagate cross-cutting state (gateways, external hosts replicated in
//!    every local zone)

use std::collections::HashMap;
use std::path::Path;

use indexmap::IndexMap;
use serde_yaml::{Mapping, Value};

use crate::error::{NixError, Result};
use crate::nix_generator::item::host::{Host, ServiceParams};
use crate::nix_generator::item::user::{filter_profile, User, UserBuildConfig};
use crate::nix_generator::nix_network::NixNetwork;
use crate::nix_generator::nix_zone::{NixZone, EXTERNAL_ZONE_KEY};
use crate::nix_generator::yaml::{as_str_opt, as_string_vec, deep_merge, to_string_map};

const MAX_RANGE_BOUND: i64 = 1000;
const DEFAULT_PROFILE: &str = "minimal";
const NIX_USER_NAME: &str = "nix";
const NIX_USER_UID: u32 = 65000;
const NIX_USER_DISPLAY: &str = "Nix Maintenance User";
const NIX_USER_PROFILE: &str = "nix-admin";

/// Keys propagated from a list/range group declaration onto each generated host.
const GROUP_INHERITED_KEYS: &[&str] = &["profile", "users", "groups", "features", "tags", "disko"];

pub struct Configuration {
    pub users: IndexMap<String, User>,
    pub hosts: IndexMap<String, Host>,
    pub network: NixNetwork,
    /// Static host DNS records: `"hostname,hostname.zonedomain,ip"`
    pub host_records: Vec<String>,
}

impl Configuration {
    pub fn load(main_yaml: &Path, generated_yaml: &Path) -> Result<Self> {
        let main_str = std::fs::read_to_string(main_yaml)?;
        // The generated YAML acts as an overlay: it may not yet exist on a
        // fresh checkout, in which case we treat it as an empty mapping.
        let gen_str = if generated_yaml.exists() {
            std::fs::read_to_string(generated_yaml)?
        } else {
            "{}".to_string()
        };

        let merged = deep_merge(
            serde_yaml::from_str(&main_str)?,
            serde_yaml::from_str(&gen_str)?,
        );

        let project_root = main_yaml
            .parent()
            .and_then(|p| p.parent())
            .ok_or_else(|| NixError::generate("Cannot determine project root"))?;

        let mut cfg = Configuration {
            users: IndexMap::new(),
            hosts: IndexMap::new(),
            network: NixNetwork::default(),
            host_records: vec![],
        };

        cfg.load_network(&merged)?;
        cfg.load_zones(&merged)?;
        cfg.load_users(&merged, project_root)?;
        cfg.load_hosts(&merged, project_root)?;

        Ok(cfg)
    }

    // ─── network ────────────────────────────────────────────────────────────

    fn load_network(&mut self, config: &Value) -> Result<()> {
        let network_raw = config.get("network").cloned().unwrap_or(Value::Null);
        self.network.register_network_config(network_raw)
    }

    // ─── zones ──────────────────────────────────────────────────────────────

    fn load_zones(&mut self, config: &Value) -> Result<()> {
        // Always declare the external "www" zone so service generation can
        // reference it even when the YAML doesn't list it.
        let mut www = NixZone::new(EXTERNAL_ZONE_KEY);
        www.register_zone_config(
            HashMap::new(),
            &self.network.config.default_locale,
            &self.network.config.default_timezone,
            &self.network.config.domain,
        )?;
        self.network.add_zone(www);

        let Some(zones) = config.get("zones").and_then(Value::as_mapping) else {
            return Ok(());
        };

        // PHP `Configuration::loadZones` discards the common-merge result (it
        // mutates a copy then passes the original to `registerZoneConfig`).
        // We mirror that quirk: `zones.common` is silently ignored here.
        for (zone_name_val, zone_cfg) in zones {
            let zone_name = zone_name_val.as_str().unwrap_or_default();
            if zone_name == "common" {
                continue;
            }
            let cfg_map = to_string_map(zone_cfg.clone());
            // Capture extraHosts before register_zone_config strips it from cfg.
            let extra_hosts = cfg_map.get("extraHosts").cloned();

            let mut zone = NixZone::new(zone_name);
            zone.register_zone_config(
                cfg_map,
                &self.network.config.default_locale,
                &self.network.config.default_timezone,
                &self.network.config.domain,
            )?;
            let ip_prefix = zone.ip_prefix().to_string();
            self.network.add_zone(zone);

            if let Some(eh) = extra_hosts {
                self.process_extra_hosts(zone_name, &ip_prefix, &eh)?;
            }
        }

        Ok(())
    }

    /// Mirrors PHP `NixZone::registerZoneConfig` — declares each `extraHosts`
    /// entry as a synthetic host on its zone (DHCP, aliases, services, DNS).
    fn process_extra_hosts(
        &mut self,
        zone_name: &str,
        ip_prefix: &str,
        extra_hosts: &Value,
    ) -> Result<()> {
        let Some(map) = extra_hosts.as_mapping() else {
            return Ok(());
        };
        for (hostname_val, host_cfg) in map {
            let Some(hostname) = hostname_val.as_str() else {
                continue;
            };
            let ip_suffix = as_str_opt(host_cfg, "ip").ok_or_else(|| {
                NixError::validation(format!("extraHosts \"{hostname}\" requires an ip"))
            })?;
            let host_ip = format!("{ip_prefix}.{ip_suffix}");
            let aliases = as_string_vec(host_cfg, "aliases");
            let services = parse_services(host_cfg, hostname)?;

            {
                let zone = self.network.get_zone_mut(zone_name)?;
                zone.register_host(hostname, Some(&host_ip), false)?;
                if let Some(mac) = as_str_opt(host_cfg, "mac") {
                    zone.register_mac_addresses(mac, &host_ip)?;
                }
                if !aliases.is_empty() {
                    zone.register_aliases(hostname, &aliases)?;
                }
            }

            if !services.is_empty() {
                self.network
                    .register_services(hostname, zone_name, &services)?;
            }
        }
        Ok(())
    }

    // ─── users ──────────────────────────────────────────────────────────────

    fn load_users(&mut self, config: &Value, project_root: &Path) -> Result<()> {
        let users = config
            .get("users")
            .and_then(Value::as_mapping)
            .ok_or_else(|| NixError::validation("Users not found in configuration"))?;

        // Pre-reserve the special nix UID so a regular user can't steal it.
        let mut uid_tracker: HashMap<u32, String> = HashMap::new();
        uid_tracker.insert(NIX_USER_UID, NIX_USER_NAME.to_string());

        for (login_val, user_cfg) in users {
            let login = login_val.as_str().unwrap_or_default();
            let uid = user_cfg
                .get("uid")
                .and_then(Value::as_u64)
                .ok_or_else(|| {
                    NixError::validation(format!("A valid uid is required for {login}"))
                })? as u32;
            let name = as_str_opt(user_cfg, "name").ok_or_else(|| {
                NixError::validation(format!("A valid user name is required for {login}"))
            })?;
            let user = User::build(UserBuildConfig {
                login,
                uid,
                name,
                email: as_str_opt(user_cfg, "email"),
                profile: as_str_opt(user_cfg, "profile").unwrap_or(DEFAULT_PROFILE),
                groups: as_string_vec(user_cfg, "groups"),
                uid_tracker: &mut uid_tracker,
                project_root,
            })?;
            self.users.insert(login.to_string(), user);
        }

        // Append the special nix maintenance user LAST (matches PHP order).
        // The profile lookup may legitimately fail in test fixtures; in that
        // case fall back to a hard-coded path.
        let nix_user = User {
            login: NIX_USER_NAME.to_string(),
            uid: NIX_USER_UID,
            name: NIX_USER_DISPLAY.to_string(),
            email: None,
            profile: filter_profile(NIX_USER_PROFILE, project_root)
                .unwrap_or_else(|_| format!("dnf/home/profiles/{NIX_USER_PROFILE}")),
            groups: vec![],
        };
        self.users.insert(NIX_USER_NAME.to_string(), nix_user);

        Ok(())
    }

    // ─── hosts ──────────────────────────────────────────────────────────────

    /// Hosts come in three flavours, dispatched by which key is present:
    /// - `range:` → `load_range_hosts` (e.g. workstations 1..N)
    /// - `hosts:` → `load_list_hosts` (e.g. `kids` and `parents` laptops)
    /// - otherwise → `load_static_hosts` (a single declared host)
    fn load_hosts(&mut self, config: &Value, project_root: &Path) -> Result<()> {
        let Some(hosts_list) = config.get("hosts").and_then(Value::as_sequence) else {
            return Ok(());
        };

        let mut static_hosts = vec![];
        let mut range_hosts = vec![];
        let mut list_hosts = vec![];
        for host in hosts_list {
            if host.get("range").is_some() {
                range_hosts.push(host.clone());
            } else if host.get("hosts").is_some() {
                list_hosts.push(host.clone());
            } else {
                static_hosts.push(host.clone());
            }
        }

        self.load_static_hosts(&static_hosts, project_root)?;
        self.load_range_hosts(&range_hosts, project_root)?;
        self.load_list_hosts(&list_hosts, project_root)?;
        self.populate_zones()?;

        Ok(())
    }

    fn load_static_hosts(&mut self, hosts: &[Value], project_root: &Path) -> Result<()> {
        for host_val in hosts {
            let hostname = as_str_opt(host_val, "hostname")
                .ok_or_else(|| NixError::validation("A hostname is required"))?;
            let name = as_str_opt(host_val, "name").ok_or_else(|| {
                NixError::validation(format!("A name is required for \"{hostname}\""))
            })?;
            let profile = as_str_opt(host_val, "profile").ok_or_else(|| {
                NixError::validation(format!("A host profile is required for \"{hostname}\""))
            })?;

            let (zone_name, ip) = self.extract_zone_and_ip(host_val, hostname)?;
            let zone_domain = if zone_name == EXTERNAL_ZONE_KEY {
                self.network.config.domain.clone()
            } else {
                self.network.get_zone(&zone_name)?.domain().to_string()
            };

            let groups = as_string_vec(host_val, "groups");
            let users = self.expand_users(&as_string_vec(host_val, "users"), &groups);
            let services = parse_services(host_val, hostname)?;
            let aliases = as_string_vec(host_val, "aliases");

            // Build the Host struct itself.
            let mut host = Host::new(hostname);
            host.name = name.to_string();
            host.zone = zone_name.clone();
            host.profile = profile.to_string();
            host.arch = as_str_opt(host_val, "arch").map(str::to_string);
            host.zone_domain = zone_domain.clone();
            host.network_domain = self.network.config.domain.clone();
            host.groups = groups;
            host.set_users(users)?;
            host.set_features(&as_string_vec(host_val, "features"));
            host.tags = as_string_vec(host_val, "tags");
            host.ip = ip.clone();
            host.vpn_ip = host_val
                .get("ipv4")
                .and_then(|v| v.get("internal"))
                .and_then(Value::as_str)
                .map(str::to_string);
            host.services = services;
            host.set_disko(disko_profile(host_val), disko_devices(host_val), project_root)?;

            // Mirror the host into the zone (DHCP, aliases) and into the
            // service registry, then publish a DNS record.
            let zone = self.network.get_zone_mut(&zone_name)?;
            zone.register_host(hostname, ip.as_deref(), false)?;
            if let (Some(ip_str), Some(mac)) = (&ip, as_str_opt(host_val, "mac")) {
                zone.register_mac_addresses(mac, ip_str)?;
            }
            if !aliases.is_empty() {
                zone.register_aliases(hostname, &aliases)?;
            }

            self.network
                .register_services(hostname, &zone_name, &host.services)?;

            if let Some(ref ip_str) = ip {
                self.register_host_record(hostname, &zone_domain, ip_str);
            }

            self.hosts.insert(hostname.to_string(), host);
        }

        Ok(())
    }

    /// Range groups generate N hosts whose names contain the index — typically
    /// `ws01`..`ws10`. The shared group keys propagate to every generated host.
    fn load_range_hosts(&mut self, range_hosts: &[Value], project_root: &Path) -> Result<()> {
        let mut static_hosts = vec![];
        for group in range_hosts {
            let range = group
                .get("range")
                .and_then(Value::as_sequence)
                .filter(|r| r.len() == 2)
                .ok_or_else(|| NixError::validation("Bad range type"))?;
            let start = range[0]
                .as_i64()
                .ok_or_else(|| NixError::validation("Bad range start"))?;
            let end = range[1]
                .as_i64()
                .ok_or_else(|| NixError::validation("Bad range end"))?;
            let count = end - start;
            if !(0..=MAX_RANGE_BOUND).contains(&count) {
                return Err(NixError::validation(format!(
                    "Range [{start}, {end}] out of bound"
                )));
            }
            for i in start..=end {
                static_hosts.push(Value::Mapping(build_range_entry(group, i)?));
            }
        }
        self.load_static_hosts(&static_hosts, project_root)
    }

    /// List groups generate one host per entry in `hosts:`, applying the
    /// group's `hostname`/`name` template (PHP `sprintf("%s", $hostname)`).
    fn load_list_hosts(&mut self, list_hosts: &[Value], project_root: &Path) -> Result<()> {
        let mut static_hosts = vec![];
        for group in list_hosts {
            let hosts_map = group
                .get("hosts")
                .and_then(Value::as_mapping)
                .ok_or_else(|| NixError::validation("Bad hosts list type"))?;
            for (hostname_val, host_cfg) in hosts_map {
                let hostname = hostname_val.as_str().unwrap_or_default();
                let host_name = as_str_opt(host_cfg, "name").ok_or_else(|| {
                    NixError::validation(format!("Bad host description for {hostname}"))
                })?;
                static_hosts.push(Value::Mapping(build_list_entry(
                    group, host_cfg, hostname, host_name,
                )));
            }
        }
        self.load_static_hosts(&static_hosts, project_root)
    }

    /// Two cross-cutting steps after every host is loaded:
    /// - any local host whose IP ends in `.1.1` is the zone's gateway;
    /// - hosts declared in the external (`www`) zone are replicated as
    ///   read-only entries in every local zone, so DNS / dnsmasq can address
    ///   them by name from inside the LAN.
    fn populate_zones(&mut self) -> Result<()> {
        let snapshots: Vec<(String, String, Option<String>, Option<String>)> = self
            .hosts
            .values()
            .map(|h| {
                (
                    h.hostname.clone(),
                    h.zone.clone(),
                    h.ip.clone(),
                    h.vpn_ip.clone(),
                )
            })
            .collect();

        for (hostname, zone, ip, vpn_ip) in &snapshots {
            // Local-zone gateway detection by IP convention.
            if zone != EXTERNAL_ZONE_KEY && ip.as_deref().is_some_and(|s| s.ends_with(".1.1")) {
                let z = self.network.get_zone_mut(zone)?;
                z.set_gateway_hostname(hostname)?;
                if let Some(ip_str) = ip {
                    z.set_gateway_lan_ip(ip_str);
                }
            }

            // External hosts are visible from every local zone.
            if zone == EXTERNAL_ZONE_KEY {
                let local_zones: Vec<String> = self
                    .network
                    .zones
                    .keys()
                    .filter(|n| n.as_str() != EXTERNAL_ZONE_KEY)
                    .cloned()
                    .collect();
                for local in local_zones {
                    self.network.get_zone_mut(&local)?.register_host(
                        hostname,
                        ip.as_deref(),
                        true,
                    )?;
                }
                if let Some(vpn) = vpn_ip {
                    let z = self.network.get_zone_mut(EXTERNAL_ZONE_KEY)?;
                    z.set_gateway_hostname(hostname)?;
                    z.set_gateway_vpn_ipv4(vpn);
                }
            }
        }

        Ok(())
    }

    // ─── shared host helpers ────────────────────────────────────────────────

    /// Resolve a host's zone and IP from either the `zone:` shorthand
    /// (`"<name>:<ip-suffix>"`) or the explicit `ipv4.external` form.
    fn extract_zone_and_ip(
        &self,
        host: &Value,
        hostname: &str,
    ) -> Result<(String, Option<String>)> {
        if let Some(zone_field) = as_str_opt(host, "zone") {
            let mut parts = zone_field.splitn(2, ':');
            let zone_name = parts.next().unwrap_or("").to_string();
            let ip_suffix = parts.next().unwrap_or("");
            let ip = if ip_suffix.is_empty() {
                None
            } else {
                let prefix = self
                    .network
                    .get_zone(&zone_name)
                    .map(|z| z.ip_prefix().to_string())
                    .unwrap_or_default();
                Some(format!("{prefix}.{ip_suffix}"))
            };
            return Ok((zone_name, ip));
        }
        if let Some(ext_ip) = host
            .get("ipv4")
            .and_then(|v| v.get("external"))
            .and_then(Value::as_str)
        {
            return Ok((EXTERNAL_ZONE_KEY.to_string(), Some(ext_ip.to_string())));
        }
        Err(NixError::validation(format!(
            "A zone name or ipv4 is required for \"{hostname}\""
        )))
    }

    /// Final user list = `nix` + explicit users + members of the host's groups.
    fn expand_users(&self, host_users: &[String], groups: &[String]) -> Vec<String> {
        let mut users: Vec<String> = vec![NIX_USER_NAME.to_string()];
        users.extend_from_slice(host_users);
        for group in groups {
            for user in self.users.values() {
                if user.groups.contains(group) {
                    users.push(user.login.clone());
                }
            }
        }
        users.sort();
        users.dedup();
        users
    }

    fn register_host_record(&mut self, hostname: &str, zone_domain: &str, ip: &str) {
        if !ip.is_empty() {
            self.host_records
                .push(format!("{hostname},{hostname}.{zone_domain},{ip}"));
        }
    }
}

// ─── free helpers ───────────────────────────────────────────────────────────

fn disko_profile(host_val: &Value) -> Option<&str> {
    host_val
        .get("disko")
        .and_then(|d| d.get("profile"))
        .and_then(Value::as_str)
}

fn disko_devices(host_val: &Value) -> HashMap<String, String> {
    host_val
        .get("disko")
        .and_then(|d| d.get("devices"))
        .and_then(Value::as_mapping)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| Some((k.as_str()?.to_string(), v.as_str()?.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

/// Extract the `services:` mapping from a host YAML node.
fn parse_services(host_val: &Value, hostname: &str) -> Result<IndexMap<String, ServiceParams>> {
    let mut result = IndexMap::new();
    let Some(services) = host_val.get("services").and_then(Value::as_mapping) else {
        return Ok(result);
    };
    for (name_val, params_val) in services {
        let name = name_val.as_str().unwrap_or_default().to_string();
        let params = params_val
            .as_mapping()
            .map(|m| ServiceParams {
                title: m.get("title").and_then(Value::as_str).map(str::to_string),
                description: m
                    .get("description")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                domain: m.get("domain").and_then(Value::as_str).map(str::to_string),
                icon: m.get("icon").and_then(Value::as_str).map(str::to_string),
                global: m.get("global").and_then(Value::as_bool).unwrap_or(false),
            })
            .unwrap_or_default();
        if result.contains_key(&name) {
            return Err(NixError::validation(format!(
                "Service {hostname}:{name} already registered"
            )));
        }
        result.insert(name, params);
    }
    Ok(result)
}

/// Build the synthetic static-host entry for index `i` of a `range:` group.
fn build_range_entry(group: &Value, i: i64) -> Result<Mapping> {
    let hostname = as_str_opt(group, "hostname")
        .map(|t| apply_template(t, i))
        .ok_or_else(|| NixError::validation("hostname template required in range"))?;
    let name = as_str_opt(group, "name")
        .map(|t| apply_template(t, i))
        .unwrap_or_else(|| hostname.clone());
    let zone = as_str_opt(group, "zone")
        .map(|t| apply_template(t, i))
        .ok_or_else(|| NixError::validation("zone required in range"))?;

    let mut host_map = Mapping::new();
    host_map.insert("hostname".into(), hostname.into());
    host_map.insert("name".into(), name.into());
    host_map.insert("zone".into(), zone.into());
    for key in GROUP_INHERITED_KEYS {
        if let Some(v) = group.get(*key) {
            host_map.insert((*key).into(), v.clone());
        }
    }
    // Per-index MAC addresses live under `mac.<i>` in YAML.
    if let Some(mac_val) = group
        .get("mac")
        .and_then(Value::as_mapping)
        .and_then(|m| m.get(Value::from(i)))
    {
        host_map.insert("mac".into(), mac_val.clone());
    }
    // Per-index field overrides under `hosts.<i>`. PHP semantics are
    // `$hosts[$id] += $extraConfig` (array union): existing keys kept,
    // only NEW keys merged in — hence `entry().or_insert()`.
    if let Some(overrides) = group
        .get("hosts")
        .and_then(Value::as_mapping)
        .and_then(|m| m.get(Value::from(i)))
        .and_then(Value::as_mapping)
    {
        for (k, v) in overrides {
            host_map.entry(k.clone()).or_insert(v.clone());
        }
    }
    Ok(host_map)
}

/// Build the synthetic static-host entry for one member of a `hosts:` list group.
///
/// PHP performs `array_merge($hostCfg, [hostname, name, profile, …])` — the
/// second array wins, so the group-level keys override the per-host config.
fn build_list_entry(group: &Value, host_cfg: &Value, hostname: &str, host_name: &str) -> Mapping {
    // PHP uses `sprintf("%s", $hostname)` — substitute the literal `%s`
    // placeholder, NOT Rust's `{}`.
    let tpl_hostname = as_str_opt(group, "hostname")
        .map(|t| t.replace("%s", hostname))
        .unwrap_or_else(|| hostname.to_string());
    let tpl_name = as_str_opt(group, "name")
        .map(|t| t.replace("%s", host_name))
        .unwrap_or_else(|| host_name.to_string());

    let mut merged = Mapping::new();
    if let Some(m) = host_cfg.as_mapping() {
        for (k, v) in m {
            merged.insert(k.clone(), v.clone());
        }
    }
    merged.insert("hostname".into(), tpl_hostname.into());
    merged.insert("name".into(), tpl_name.into());
    if let Some(v) = group.get("profile") {
        merged.insert("profile".into(), v.clone());
    }
    // Force-default the list keys to `[]` so downstream `as_string_vec`
    // returns empty rather than panicking on a type mismatch.
    for key in &["users", "groups", "features", "tags", "disko"] {
        let v = group.get(key).cloned().unwrap_or(Value::Sequence(vec![]));
        merged.insert((*key).into(), v);
    }
    merged
}

/// Apply a PHP-sprintf-style template substitution for range host names.
/// Supported: `%'<pad><width>s` (e.g. `%'02s` → zero-padded), `%d`, `%s`.
fn apply_template(template: &str, value: i64) -> String {
    let s = value.to_string();
    let padded = regex::Regex::new(r"%'([^%])(\d+)s")
        .expect("valid regex")
        .replace_all(template, |caps: &regex::Captures| {
            let pad_char = caps[1].chars().next().unwrap_or('0');
            let width: usize = caps[2].parse().unwrap_or(0);
            if s.len() >= width {
                s.clone()
            } else {
                let padding: String = std::iter::repeat_n(pad_char, width - s.len()).collect();
                format!("{padding}{s}")
            }
        })
        .to_string();
    padded.replace("%d", &s).replace("%s", &s)
}
