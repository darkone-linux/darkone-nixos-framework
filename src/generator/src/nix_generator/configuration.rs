use std::collections::HashMap;
use std::path::Path;

use indexmap::IndexMap;
use serde_yaml::Value;

use crate::error::{NixError, Result};
use crate::nix_generator::item::host::{Host, ServiceParams};
use crate::nix_generator::item::user::User;
use crate::nix_generator::nix_network::NixNetwork;
use crate::nix_generator::nix_zone::{EXTERNAL_ZONE_KEY, NixZone};

const MAX_RANGE_BOUND: i64 = 1000;
const DEFAULT_PROFILE: &str = "minimal";
const NIX_USER_NAME: &str = "nix";
const NIX_USER_UID: u32 = 65000;
const NIX_USER_DISPLAY: &str = "Nix Maintenance User";
const NIX_USER_PROFILE: &str = "nix-admin";

pub struct Configuration {
    pub users: IndexMap<String, User>,
    pub hosts: IndexMap<String, Host>,
    pub network: NixNetwork,
    /// Static host DNS records: "hostname,hostname.zonedomain,ip"
    pub host_records: Vec<String>,
}

impl Configuration {
    pub fn load(main_yaml: &Path, generated_yaml: &Path) -> Result<Self> {
        // Parse both YAML files
        let main_str = std::fs::read_to_string(main_yaml)?;
        let gen_str = if generated_yaml.exists() {
            std::fs::read_to_string(generated_yaml)?
        } else {
            "{}".to_string()
        };

        let main: Value = serde_yaml::from_str(&main_str)?;
        let generated: Value = serde_yaml::from_str(&gen_str)?;

        // Deep merge: generated values override main
        let config = deep_merge(main, generated);

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

        cfg.load_network(&config)?;
        cfg.load_zones(&config)?;
        cfg.load_users(&config, project_root)?;
        cfg.load_hosts(&config, project_root)?;

        Ok(cfg)
    }

    fn load_network(&mut self, config: &Value) -> Result<()> {
        let network_raw = config.get("network").cloned().unwrap_or(Value::Null);
        self.network.register_network_config(network_raw)
    }

    fn load_zones(&mut self, config: &Value) -> Result<()> {
        // Always add the external "www" zone
        let mut www = NixZone::new(EXTERNAL_ZONE_KEY);
        www.register_zone_config(
            HashMap::new(),
            &self.network.config.default_locale,
            &self.network.config.default_timezone,
            &self.network.config.domain,
        )?;
        self.network.add_zone(www);

        let zones = match config.get("zones").and_then(|z| z.as_mapping()) {
            Some(m) => m,
            None => return Ok(()),
        };

        let common_cfg = zones
            .get("common")
            .cloned()
            .unwrap_or(Value::Mapping(Default::default()));

        for (zone_name_val, zone_cfg) in zones {
            let zone_name = zone_name_val.as_str().unwrap_or_default();
            if zone_name == "common" {
                continue;
            }
            // Merge common config into zone config (zone-specific values take priority)
            let merged = deep_merge(common_cfg.clone(), zone_cfg.clone());
            let cfg_map = yaml_to_string_map(merged);

            let mut zone = NixZone::new(zone_name);
            zone.register_zone_config(
                cfg_map,
                &self.network.config.default_locale,
                &self.network.config.default_timezone,
                &self.network.config.domain,
            )?;
            self.network.add_zone(zone);
        }

        Ok(())
    }

    fn load_users(&mut self, config: &Value, project_root: &Path) -> Result<()> {
        let users = config
            .get("users")
            .and_then(|u| u.as_mapping())
            .ok_or_else(|| NixError::validation("Users not found in configuration"))?;

        let mut uid_tracker: HashMap<u32, String> = HashMap::new();

        // Special nix maintenance user (uid 65000, bypass range check via direct insertion)
        uid_tracker.insert(NIX_USER_UID, NIX_USER_NAME.to_string());
        let nix_user = User {
            login: NIX_USER_NAME.to_string(),
            uid: NIX_USER_UID,
            name: NIX_USER_DISPLAY.to_string(),
            email: None,
            profile: User::filter_profile_unchecked(NIX_USER_PROFILE, project_root)
                .unwrap_or_else(|_| format!("dnf/home/profiles/{NIX_USER_PROFILE}")),
            groups: vec![],
        };
        self.users.insert(NIX_USER_NAME.to_string(), nix_user);

        for (login_val, user_cfg) in users {
            let login = login_val.as_str().unwrap_or_default();
            let uid = user_cfg
                .get("uid")
                .and_then(|v| v.as_u64())
                .ok_or_else(|| {
                    NixError::validation(format!("A valid uid is required for {login}"))
                })? as u32;
            let name = user_cfg
                .get("name")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    NixError::validation(format!("A valid user name is required for {login}"))
                })?;
            let email = user_cfg.get("email").and_then(|v| v.as_str());
            let profile = user_cfg
                .get("profile")
                .and_then(|v| v.as_str())
                .unwrap_or(DEFAULT_PROFILE);
            let groups: Vec<String> = user_cfg
                .get("groups")
                .and_then(|v| v.as_sequence())
                .map(|seq| {
                    seq.iter()
                        .filter_map(|v| v.as_str())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();

            let user = User::new(
                login,
                uid,
                name,
                email,
                profile,
                groups,
                &mut uid_tracker,
                project_root,
            )?;
            self.users.insert(login.to_string(), user);
        }

        Ok(())
    }

    fn load_hosts(&mut self, config: &Value, project_root: &Path) -> Result<()> {
        let hosts_list = match config.get("hosts").and_then(|h| h.as_sequence()) {
            Some(h) => h,
            None => return Ok(()),
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
            let hostname = host_val
                .get("hostname")
                .and_then(|v| v.as_str())
                .ok_or_else(|| NixError::validation("A hostname is required"))?;

            let name = host_val
                .get("name")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    NixError::validation(format!("A name is required for \"{hostname}\""))
                })?;

            let profile = host_val
                .get("profile")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    NixError::validation(format!("A host profile is required for \"{hostname}\""))
                })?;

            let arch = host_val.get("arch").and_then(|v| v.as_str()).map(str::to_string);

            let (zone_name, ip) = self.extract_zone_and_ip(host_val, hostname)?;

            let zone_domain = if zone_name == EXTERNAL_ZONE_KEY {
                self.network.config.domain.clone()
            } else {
                self.network
                    .get_zone(&zone_name)?
                    .domain()
                    .to_string()
            };
            let network_domain = self.network.config.domain.clone();

            let user_logins: Vec<String> = host_val
                .get("users")
                .and_then(|v| v.as_sequence())
                .map(|s| {
                    s.iter()
                        .filter_map(|v| v.as_str())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();

            let groups: Vec<String> = host_val
                .get("groups")
                .and_then(|v| v.as_sequence())
                .map(|s| {
                    s.iter()
                        .filter_map(|v| v.as_str())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();

            let all_users = self.extract_all_users(&user_logins, &groups);

            let features: Vec<String> = host_val
                .get("features")
                .and_then(|v| v.as_sequence())
                .map(|s| {
                    s.iter()
                        .filter_map(|v| v.as_str())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();

            let tags: Vec<String> = host_val
                .get("tags")
                .and_then(|v| v.as_sequence())
                .map(|s| {
                    s.iter()
                        .filter_map(|v| v.as_str())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();

            let vpn_ip = host_val
                .get("ipv4")
                .and_then(|v| v.get("internal"))
                .and_then(|v| v.as_str())
                .map(str::to_string);

            let services = parse_services(host_val, hostname)?;

            let disko_profile = host_val
                .get("disko")
                .and_then(|d| d.get("profile"))
                .and_then(|v| v.as_str());
            let disko_devices = host_val
                .get("disko")
                .and_then(|d| d.get("devices"))
                .and_then(|v| v.as_mapping())
                .map(|m| {
                    m.iter()
                        .filter_map(|(k, v)| {
                            Some((k.as_str()?.to_string(), v.as_str()?.to_string()))
                        })
                        .collect::<HashMap<_, _>>()
                })
                .unwrap_or_default();

            let mut host = Host::new(hostname);
            host.name = name.to_string();
            host.zone = zone_name.clone();
            host.profile = profile.to_string();
            host.arch = arch;
            host.zone_domain = zone_domain.clone();
            host.network_domain = network_domain;
            host.groups = groups.clone();
            host.set_users(all_users)?;
            host.set_features(&features);
            host.tags = tags;
            host.ip = ip.clone();
            host.vpn_ip = vpn_ip;
            host.services = services;
            host.set_disko(disko_profile, disko_devices, project_root)?;

            // Register in zone
            let zone = self.network.get_zone_mut(&zone_name)?;
            let aliases: Vec<String> = host_val
                .get("aliases")
                .and_then(|v| v.as_sequence())
                .map(|s| {
                    s.iter()
                        .filter_map(|v| v.as_str())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();
            zone.register_host(hostname, ip.as_deref(), false)?;
            if let Some(ip_str) = &ip {
                if let Some(mac) = host_val.get("mac").and_then(|v| v.as_str()) {
                    zone.register_mac_addresses(mac, ip_str)?;
                }
            }
            if !aliases.is_empty() {
                zone.register_aliases(hostname, &aliases)?;
            }

            // Register services
            self.network.register_services(hostname, &zone_name, &host.services)?;

            // DNS host record
            if let Some(ref ip_str) = ip {
                self.register_host_record(hostname, &zone_domain, ip_str)?;
            }

            self.hosts.insert(hostname.to_string(), host);
        }

        Ok(())
    }

    fn load_range_hosts(&mut self, range_hosts: &[Value], project_root: &Path) -> Result<()> {
        let mut static_hosts = vec![];
        for group in range_hosts {
            let range = group
                .get("range")
                .and_then(|r| r.as_sequence())
                .filter(|r| r.len() == 2)
                .ok_or_else(|| NixError::validation("Bad range type"))?;
            let start = range[0].as_i64().ok_or_else(|| NixError::validation("Bad range start"))?;
            let end = range[1].as_i64().ok_or_else(|| NixError::validation("Bad range end"))?;
            let count = end - start;
            if count < 0 || count > MAX_RANGE_BOUND {
                return Err(NixError::validation(format!(
                    "Range [{start}, {end}] out of bound"
                )));
            }
            for i in start..=end {
                let hostname = group
                    .get("hostname")
                    .and_then(|v| v.as_str())
                    .map(|t| apply_template(t, i))
                    .ok_or_else(|| NixError::validation("hostname template required in range"))?;
                let name = group
                    .get("name")
                    .and_then(|v| v.as_str())
                    .map(|t| apply_template(t, i))
                    .unwrap_or_else(|| hostname.clone());
                let zone = group
                    .get("zone")
                    .and_then(|v| v.as_str())
                    .map(|t| apply_template(t, i))
                    .ok_or_else(|| NixError::validation("zone required in range"))?;

                let mut host_map = serde_yaml::Mapping::new();
                host_map.insert("hostname".into(), hostname.into());
                host_map.insert("name".into(), name.into());
                host_map.insert("zone".into(), zone.into());
                for key in &["profile", "users", "groups", "features", "tags", "disko"] {
                    if let Some(v) = group.get(key) {
                        host_map.insert((*key).into(), v.clone());
                    }
                }
                // Per-index mac overrides
                if let Some(mac_val) = group
                    .get("mac")
                    .and_then(|m| m.as_mapping())
                    .and_then(|m| m.get(&Value::from(i)))
                {
                    host_map.insert("mac".into(), mac_val.clone());
                }
                // Per-index overrides from hosts sub-key
                if let Some(overrides) = group
                    .get("hosts")
                    .and_then(|h| h.as_mapping())
                    .and_then(|m| m.get(&Value::from(i)))
                    .and_then(|v| v.as_mapping())
                {
                    for (k, v) in overrides {
                        host_map.insert(k.clone(), v.clone());
                    }
                }
                static_hosts.push(Value::Mapping(host_map));
            }
        }
        self.load_static_hosts(&static_hosts, project_root)
    }

    fn load_list_hosts(&mut self, list_hosts: &[Value], project_root: &Path) -> Result<()> {
        let mut static_hosts = vec![];
        for group in list_hosts {
            let hosts_map = group
                .get("hosts")
                .and_then(|h| h.as_mapping())
                .ok_or_else(|| NixError::validation("Bad hosts list type"))?;
            for (hostname_val, host_cfg) in hosts_map {
                let hostname = hostname_val.as_str().unwrap_or_default();
                let host_name = host_cfg
                    .get("name")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| {
                        NixError::validation(format!("Bad host description for {hostname}"))
                    })?;
                let tpl_hostname = group
                    .get("hostname")
                    .and_then(|v| v.as_str())
                    .map(|t| t.replace("{}", hostname))
                    .unwrap_or_else(|| hostname.to_string());
                let tpl_name = group
                    .get("name")
                    .and_then(|v| v.as_str())
                    .map(|t| t.replace("{}", host_name))
                    .unwrap_or_else(|| host_name.to_string());

                let mut merged = serde_yaml::Mapping::new();
                // Start with host-specific config
                if let Some(m) = host_cfg.as_mapping() {
                    for (k, v) in m {
                        merged.insert(k.clone(), v.clone());
                    }
                }
                merged.insert("hostname".into(), tpl_hostname.into());
                merged.insert("name".into(), tpl_name.into());
                for key in &["profile", "users", "groups", "features", "tags", "disko"] {
                    if let Some(v) = group.get(key) {
                        merged.entry((*key).into()).or_insert(v.clone());
                    }
                }
                static_hosts.push(Value::Mapping(merged));
            }
        }
        self.load_static_hosts(&static_hosts, project_root)
    }

    fn populate_zones(&mut self) -> Result<()> {
        let hosts: Vec<(String, String, Option<String>, Option<String>)> = self
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

        for (hostname, zone, ip, vpn_ip) in &hosts {
            // Gateway detection: local host whose IP ends with ".1.1"
            if zone != EXTERNAL_ZONE_KEY {
                if ip.as_deref().map_or(false, |s| s.ends_with(".1.1")) {
                    let z = self.network.get_zone_mut(zone)?;
                    z.set_gateway_hostname(&hostname)?;
                    if let Some(ip_str) = ip {
                        z.set_gateway_lan_ip(ip_str);
                    }
                }
            }

            // External hosts: register them in all local zones
            if zone == EXTERNAL_ZONE_KEY {
                let local_zone_names: Vec<String> = self
                    .network
                    .zones
                    .keys()
                    .filter(|n| n.as_str() != EXTERNAL_ZONE_KEY)
                    .cloned()
                    .collect();
                for local_name in local_zone_names {
                    self.network
                        .get_zone_mut(&local_name)?
                        .register_host(hostname, ip.as_deref(), true)?;
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

    fn extract_zone_and_ip(
        &self,
        host: &Value,
        hostname: &str,
    ) -> Result<(String, Option<String>)> {
        if let Some(zone_field) = host.get("zone").and_then(|v| v.as_str()) {
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
            Ok((zone_name, ip))
        } else if let Some(ext_ip) = host
            .get("ipv4")
            .and_then(|v| v.get("external"))
            .and_then(|v| v.as_str())
        {
            Ok((EXTERNAL_ZONE_KEY.to_string(), Some(ext_ip.to_string())))
        } else {
            Err(NixError::validation(format!(
                "A zone name or ipv4 is required for \"{hostname}\""
            )))
        }
    }

    fn extract_all_users(&self, host_users: &[String], groups: &[String]) -> Vec<String> {
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

    fn register_host_record(
        &mut self,
        hostname: &str,
        zone_domain: &str,
        ip: &str,
    ) -> Result<()> {
        if !ip.is_empty() {
            self.host_records
                .push(format!("{hostname},{hostname}.{zone_domain},{ip}"));
        }
        Ok(())
    }
}

fn parse_services(
    host_val: &Value,
    hostname: &str,
) -> Result<IndexMap<String, ServiceParams>> {
    let mut result = IndexMap::new();
    let services = match host_val.get("services").and_then(|v| v.as_mapping()) {
        Some(m) => m,
        None => return Ok(result),
    };
    for (name_val, params_val) in services {
        let name = name_val.as_str().unwrap_or_default().to_string();
        let params = params_val
            .as_mapping()
            .map(|m| ServiceParams {
                title: m
                    .get("title")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
                description: m
                    .get("description")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
                domain: m
                    .get("domain")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
                icon: m
                    .get("icon")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
                global: m
                    .get("global")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false),
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

/// Apply a PHP-sprintf-style template substitution for range host names.
/// Supported: `%'<pad><width>s` (e.g. `%'02s` → zero-padded), `%d`, `%s`.
fn apply_template(template: &str, value: i64) -> String {
    let s = value.to_string();
    let mut result = template.to_string();

    // %'<pad_char><width>s — e.g. %'02s pads with '0' to width 2
    let re = regex::Regex::new(r"%'([^%])(\d+)s").expect("valid regex");
    result = re
        .replace_all(&result, |caps: &regex::Captures| {
            let pad_char = caps[1].chars().next().unwrap_or('0');
            let width: usize = caps[2].parse().unwrap_or(0);
            if s.len() >= width {
                s.clone()
            } else {
                let padding: String = std::iter::repeat(pad_char).take(width - s.len()).collect();
                format!("{padding}{s}")
            }
        })
        .to_string();

    result.replace("%d", &s).replace("%s", &s)
}

/// Recursively merge two YAML values. `overlay` keys win over `base`.
pub fn deep_merge(base: Value, overlay: Value) -> Value {
    match (base, overlay) {
        (Value::Mapping(mut b), Value::Mapping(o)) => {
            for (k, v) in o {
                let merged = if let Some(bv) = b.remove(&k) {
                    deep_merge(bv, v)
                } else {
                    v
                };
                b.insert(k, merged);
            }
            Value::Mapping(b)
        }
        (_, o) => o,
    }
}

/// Convert a serde_yaml Mapping to HashMap<String, Value>.
pub fn yaml_to_string_map(value: Value) -> HashMap<String, Value> {
    match value {
        Value::Mapping(m) => m
            .into_iter()
            .filter_map(|(k, v)| Some((k.as_str()?.to_string(), v)))
            .collect(),
        _ => HashMap::new(),
    }
}
