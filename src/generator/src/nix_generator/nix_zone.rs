use std::collections::{HashMap, HashSet};

use crate::error::{NixError, Result};
use crate::nix_generator::validation::{assert_regex, assert_tailscale_ip, RE_MAC_ADDRESS};

const DEFAULT_LAN_IP_PREFIX: &str = "10.1";
const LAN_PREFIX_LENGTH: u8 = 16;
pub const EXTERNAL_ZONE_KEY: &str = "www";

#[derive(Debug)]
pub struct NixZone {
    pub name: String,
    /// MAC -> "mac,ip" entry for dnsmasq dhcp-host
    mac_addresses: HashMap<String, String>,
    /// All MAC addresses registered globally (for duplicate detection)
    all_macs: HashSet<String>,
    /// hostname -> list of aliases
    aliases: HashMap<String, Vec<String>>,
    /// All aliases registered (for duplicate detection)
    all_aliases: HashSet<String>,
    /// hostname -> `Option<ip>`
    hosts: HashMap<String, Option<String>>,
    pub dhcp_range: Vec<String>,
    pub config: HashMap<String, serde_yaml::Value>,
}

impl NixZone {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            mac_addresses: HashMap::new(),
            all_macs: HashSet::new(),
            aliases: HashMap::new(),
            all_aliases: HashSet::new(),
            hosts: HashMap::new(),
            dhcp_range: vec![],
            config: HashMap::new(),
        }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn is_external(&self) -> bool {
        self.name == EXTERNAL_ZONE_KEY
    }

    pub fn domain(&self) -> &str {
        self.config
            .get("domain")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
    }

    pub fn ip_prefix(&self) -> &str {
        self.config
            .get("ipPrefix")
            .and_then(|v| v.as_str())
            .unwrap_or(DEFAULT_LAN_IP_PREFIX)
    }

    pub fn gateway_lan_ip(&self) -> Option<&str> {
        self.config.get("gateway")?.get("lan")?.get("ip")?.as_str()
    }

    pub fn gateway_vpn_ipv4(&self) -> Option<&str> {
        self.config
            .get("gateway")?
            .get("vpn")?
            .get("ipv4")?
            .as_str()
    }

    pub fn hosts(&self) -> &HashMap<String, Option<String>> {
        &self.hosts
    }

    pub fn mac_addresses(&self) -> &HashMap<String, String> {
        &self.mac_addresses
    }

    pub fn aliases(&self) -> &HashMap<String, Vec<String>> {
        &self.aliases
    }

    pub fn register_host(&mut self, host: &str, ip: Option<&str>, force: bool) -> Result<()> {
        if host.is_empty() {
            return Ok(());
        }
        if !force && self.hosts.contains_key(host) {
            return Err(NixError::validation(format!(
                "Hostname {host} already declared"
            )));
        }
        if let Some(ip_str) = ip {
            if self.hosts.values().any(|v| v.as_deref() == Some(ip_str)) {
                return Err(NixError::validation(format!(
                    "Ip address {ip_str} assigned to more than one host"
                )));
            }
        }
        self.hosts
            .entry(host.to_string())
            .and_modify(|v| {
                if ip.is_some() {
                    *v = ip.map(str::to_string);
                }
            })
            .or_insert_with(|| ip.map(str::to_string));
        Ok(())
    }

    pub fn register_mac_addresses(&mut self, mac: &str, ip: &str) -> Result<()> {
        for part in mac.split(',') {
            assert_regex(
                RE_MAC_ADDRESS,
                part,
                &format!("Bad mac address syntax \"{mac}\""),
            )?;
            if self.all_macs.contains(part) {
                return Err(NixError::validation(format!(
                    "Mac address {part} duplicated"
                )));
            }
            self.all_macs.insert(part.to_string());
        }
        if self.mac_addresses.contains_key(ip) {
            return Err(NixError::validation(format!(
                "Ip address {ip} conflict (mac: {mac} vs {})",
                self.mac_addresses[ip]
            )));
        }
        self.mac_addresses
            .insert(ip.to_string(), format!("{mac},{ip}"));
        Ok(())
    }

    pub fn register_aliases(&mut self, host: &str, aliases: &[String]) -> Result<()> {
        for alias in aliases {
            if self.aliases.contains_key(alias) {
                return Err(NixError::validation(format!(
                    "Alias name {alias} already declared in main hosts"
                )));
            }
            if self.hosts.contains_key(alias) {
                return Err(NixError::validation(format!(
                    "Name {alias} cannot be alias and main host name"
                )));
            }
            if self.all_aliases.contains(alias) {
                return Err(NixError::validation(format!("Duplicated alias {alias}")));
            }
            self.all_aliases.insert(alias.clone());
        }
        self.aliases
            .entry(host.to_string())
            .or_default()
            .extend(aliases.iter().cloned());
        Ok(())
    }

    pub fn set_gateway_lan_ip(&mut self, ip: &str) {
        self.set_gateway_field(&["lan", "ip"], ip.into());
    }

    pub fn set_gateway_vpn_ipv4(&mut self, ip: &str) {
        self.set_gateway_field(&["vpn", "ipv4"], ip.into());
    }

    pub fn set_gateway_hostname(&mut self, hostname: &str) -> Result<()> {
        if let Some(existing) = self
            .config
            .get("gateway")
            .and_then(|g| g.get("hostname"))
            .and_then(serde_yaml::Value::as_str)
        {
            return Err(NixError::validation(format!(
                "Zone \"{}\" already has a gateway \"{existing}\", cannot set \"{hostname}\"",
                self.name
            )));
        }
        self.set_gateway_field(&["hostname"], hostname.into());
        Ok(())
    }

    /// Insert `value` at `gateway.<path…>` inside `self.config`, creating any
    /// intermediate mappings as needed. Mirrors PHP's nested-array assignment.
    fn set_gateway_field(&mut self, path: &[&str], value: serde_yaml::Value) {
        let gw = self
            .config
            .entry("gateway".to_string())
            .or_insert_with(|| serde_yaml::Value::Mapping(Default::default()));
        if !matches!(gw, serde_yaml::Value::Mapping(_)) {
            *gw = serde_yaml::Value::Mapping(Default::default());
        }
        if let serde_yaml::Value::Mapping(map) = gw {
            insert_nested(map, path, value);
        }
    }

    /// Validate and set zone config from YAML, applying defaults.
    pub fn register_zone_config(
        &mut self,
        mut cfg: HashMap<String, serde_yaml::Value>,
        default_locale: &str,
        default_timezone: &str,
        network_domain: &str,
    ) -> Result<()> {
        cfg.entry("locale".to_string())
            .or_insert_with(|| default_locale.into());
        cfg.entry("timezone".to_string())
            .or_insert_with(|| default_timezone.into());
        cfg.entry("description".to_string())
            .or_insert_with(|| format!("{} network zone", self.name).into());

        let locale = cfg["locale"].as_str().unwrap_or("").to_string();
        cfg.entry("lang".to_string())
            .or_insert_with(|| locale[..2].into());

        let domain = if self.is_external() {
            network_domain.to_string()
        } else {
            format!("{}.{network_domain}", self.name)
        };
        cfg.insert("domain".to_string(), domain.into());

        if !self.is_external() {
            let ip_prefix = cfg
                .get("ipPrefix")
                .and_then(|v| v.as_str())
                .unwrap_or(DEFAULT_LAN_IP_PREFIX)
                .to_string();
            cfg.entry("ipPrefix".to_string())
                .or_insert_with(|| ip_prefix.clone().into());
            cfg.insert("networkIp".to_string(), format!("{ip_prefix}.0.0").into());
            cfg.insert(
                "prefixLength".to_string(),
                (LAN_PREFIX_LENGTH as i64).into(),
            );

            // Validate gateway config if present
            if cfg.contains_key("gateway") {
                self.assert_gw_cfg(&cfg)?;
            }

            // DHCP range: use configured or default
            let default_range = format!("{ip_prefix}.3.200,{ip_prefix}.3.249,24h");
            self.dhcp_range = cfg
                .get("gateway")
                .and_then(|g| g.get("lan"))
                .and_then(|l| l.get("dhcp-range"))
                .and_then(|r| r.as_sequence())
                .map(|seq| {
                    seq.iter()
                        .filter_map(|v| v.as_str())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_else(|| vec![default_range]);
        }

        // Remove keys that are processed internally and must not appear in Nix output
        cfg.remove("extraHosts");
        // Remove dhcp-range from gateway.lan (used internally for DHCP range computation)
        if let Some(serde_yaml::Value::Mapping(gw)) = cfg.get_mut("gateway") {
            if let Some(serde_yaml::Value::Mapping(lan)) =
                gw.get_mut(serde_yaml::Value::String("lan".to_string()))
            {
                lan.remove("dhcp-range");
            }
        }

        self.config = cfg;
        Ok(())
    }

    fn assert_gw_cfg(&self, cfg: &HashMap<String, serde_yaml::Value>) -> Result<()> {
        let gw = cfg.get("gateway").expect("gateway key checked above");
        if gw
            .get("wan")
            .and_then(|w| w.get("interface"))
            .and_then(|i| i.as_str())
            .is_none()
        {
            return Err(NixError::validation("A WAN interface is required"));
        }
        let lan_ifaces = gw
            .get("lan")
            .and_then(|l| l.get("interfaces"))
            .and_then(|i| i.as_sequence());
        if lan_ifaces.is_none_or(|s| s.is_empty()) {
            return Err(NixError::validation("Valid LAN interfaces are required"));
        }
        if let Some(vpn_ip) = gw
            .get("vpn")
            .and_then(|v| v.get("ipv4"))
            .and_then(|i| i.as_str())
        {
            assert_tailscale_ip(vpn_ip)?;
        }
        Ok(())
    }
}

/// Walk `path` inside `root`, creating intermediate mappings, and insert `value`
/// at the final key. Used by `set_gateway_*` to mirror PHP nested-assignment.
fn insert_nested(root: &mut serde_yaml::Mapping, path: &[&str], value: serde_yaml::Value) {
    let Some((last, prefix)) = path.split_last() else {
        return;
    };
    let mut cursor = root;
    for segment in prefix {
        let entry = cursor
            .entry(serde_yaml::Value::String((*segment).to_string()))
            .or_insert_with(|| serde_yaml::Value::Mapping(Default::default()));
        let serde_yaml::Value::Mapping(map) = entry else {
            *entry = serde_yaml::Value::Mapping(Default::default());
            let serde_yaml::Value::Mapping(map) = entry else {
                unreachable!()
            };
            cursor = map;
            continue;
        };
        cursor = map;
    }
    cursor.insert(serde_yaml::Value::String((*last).to_string()), value);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_host_basic() {
        let mut z = NixZone::new("lab");
        assert!(z.register_host("server1", Some("10.1.2.1"), false).is_ok());
        assert_eq!(
            z.hosts().get("server1").and_then(Option::as_deref),
            Some("10.1.2.1")
        );
    }

    #[test]
    fn register_host_duplicate_fails() {
        let mut z = NixZone::new("lab");
        z.register_host("server1", Some("10.1.2.1"), false).unwrap();
        assert!(z.register_host("server1", Some("10.1.2.2"), false).is_err());
    }

    #[test]
    fn register_host_ip_conflict_fails() {
        let mut z = NixZone::new("lab");
        z.register_host("srv1", Some("10.1.2.1"), false).unwrap();
        assert!(z.register_host("srv2", Some("10.1.2.1"), false).is_err());
    }

    #[test]
    fn register_mac_valid() {
        let mut z = NixZone::new("lab");
        assert!(z
            .register_mac_addresses("aa:bb:cc:dd:ee:ff", "10.1.2.1")
            .is_ok());
        assert!(z.mac_addresses().contains_key("10.1.2.1"));
    }

    #[test]
    fn register_mac_duplicate_fails() {
        let mut z = NixZone::new("lab");
        z.register_mac_addresses("aa:bb:cc:dd:ee:ff", "10.1.2.1")
            .unwrap();
        assert!(z
            .register_mac_addresses("aa:bb:cc:dd:ee:ff", "10.1.2.2")
            .is_err());
    }

    #[test]
    fn register_aliases_valid() {
        let mut z = NixZone::new("lab");
        z.register_host("server1", Some("10.1.2.1"), false).unwrap();
        assert!(z
            .register_aliases("server1", &["srv1".to_string(), "s1".to_string()])
            .is_ok());
    }

    #[test]
    fn register_alias_duplicate_fails() {
        let mut z = NixZone::new("lab");
        z.register_host("a", Some("10.1.2.1"), false).unwrap();
        z.register_host("b", Some("10.1.2.2"), false).unwrap();
        z.register_aliases("a", &["alias1".to_string()]).unwrap();
        assert!(z.register_aliases("b", &["alias1".to_string()]).is_err());
    }

    #[test]
    fn dhcp_range_default() {
        let mut z = NixZone::new("lab");
        let cfg: HashMap<String, serde_yaml::Value> = HashMap::new();
        z.register_zone_config(cfg, "fr_FR.UTF-8", "Europe/Paris", "darkone.lan")
            .unwrap();
        assert_eq!(z.dhcp_range, vec!["10.1.3.200,10.1.3.249,24h"]);
    }

    #[test]
    fn external_zone_no_dhcp() {
        let mut z = NixZone::new(EXTERNAL_ZONE_KEY);
        let cfg: HashMap<String, serde_yaml::Value> = HashMap::new();
        z.register_zone_config(cfg, "fr_FR.UTF-8", "Europe/Paris", "darkone.lan")
            .unwrap();
        assert!(z.dhcp_range.is_empty());
        assert_eq!(z.domain(), "darkone.lan");
    }

    #[test]
    fn local_zone_domain() {
        let mut z = NixZone::new("prod");
        let cfg: HashMap<String, serde_yaml::Value> = HashMap::new();
        z.register_zone_config(cfg, "fr_FR.UTF-8", "Europe/Paris", "darkone.lan")
            .unwrap();
        assert_eq!(z.domain(), "prod.darkone.lan");
    }
}
