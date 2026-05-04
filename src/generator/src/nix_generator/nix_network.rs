use std::collections::{HashMap, HashSet};

use indexmap::IndexMap;

use crate::error::{NixError, Result};
use crate::nix_generator::item::host::ServiceParams;
use crate::nix_generator::nix_service::{NixService, UNIQUE_SERVICES_BY_ZONE};
use crate::nix_generator::nix_zone::{NixZone, EXTERNAL_ZONE_KEY};
use crate::nix_generator::validation::{
    assert_email, assert_regex, RE_FQDN, RE_HOSTNAME, RE_LOCALE, RE_SMTP_PROTOCOL, RE_TIMEZONE,
};

const DEFAULT_DOMAIN: &str = "darkone.lan";
const DEFAULT_LOCALE: &str = "fr_FR.UTF-8";
const DEFAULT_TIMEZONE: &str = "Europe/Paris";
const DEFAULT_COORDINATION_DOMAIN: &str = "headscale";

#[derive(Debug, Default)]
pub struct NetworkConfig {
    pub domain: String,
    pub default_locale: String,
    pub default_timezone: String,
    pub coordination_domain: String,
    pub coordination_hostname: String,
    pub coordination_enable: bool,
    /// Full raw config for output
    pub raw: serde_yaml::Value,
}

#[derive(Debug, Default)]
pub struct NixNetwork {
    pub config: NetworkConfig,
    pub zones: HashMap<String, NixZone>,
    /// Services in declaration order (IndexMap preserves insertion order)
    services: IndexMap<String, NixService>,
    /// Track unique services per zone: (zone, service_name) -> bool
    uniq_services: HashMap<(String, String), bool>,
    /// Track global service domain names to detect conflicts
    global_service_domains: HashSet<String>,
}

impl NixNetwork {
    pub fn add_zone(&mut self, zone: NixZone) {
        self.zones.insert(zone.name.clone(), zone);
    }

    pub fn get_zone(&self, name: &str) -> Result<&NixZone> {
        self.zones
            .get(name)
            .ok_or_else(|| NixError::validation(format!("Undefined zone \"{name}\"")))
    }

    pub fn get_zone_mut(&mut self, name: &str) -> Result<&mut NixZone> {
        self.zones
            .get_mut(name)
            .ok_or_else(|| NixError::validation(format!("Undefined zone \"{name}\"")))
    }

    pub fn services(&self) -> &IndexMap<String, NixService> {
        &self.services
    }

    /// Services in declaration order (matches PHP insertion order).
    pub fn services_as_vec(&self) -> Vec<&NixService> {
        self.services.values().collect()
    }

    /// Register all services declared on a host.
    /// `hostname`: the host registering the services
    /// `zone`: the host's zone name
    /// `services`: map of service_name -> service params
    pub fn register_services(
        &mut self,
        hostname: &str,
        zone: &str,
        services: &IndexMap<String, ServiceParams>,
    ) -> Result<()> {
        for (service_name, params) in services {
            let mut is_global = params.global;
            let service_domain = params.domain.as_deref().unwrap_or(service_name);

            // Services that must be unique per zone
            if UNIQUE_SERVICES_BY_ZONE.contains(&service_name.as_str()) {
                let key = (zone.to_string(), service_name.clone());
                if self.uniq_services.contains_key(&key) {
                    return Err(NixError::validation(format!(
                        "Service {service_name} must be unique in zone {zone}"
                    )));
                }
                self.uniq_services.insert(key, true);
            }

            // External zone services are implicitly global
            if zone == EXTERNAL_ZONE_KEY {
                is_global = true;
            }

            // Global domain conflict check
            if is_global {
                if self.global_service_domains.contains(service_domain) {
                    return Err(NixError::validation(format!(
                        "Global services domain name conflict: {service_name}"
                    )));
                }
                self.global_service_domains
                    .insert(service_domain.to_string());
            }

            // Zone-level domain conflict check
            let key = format!("{zone}:{service_domain}");
            if self.services.contains_key(&key) {
                return Err(NixError::validation(format!(
                    "Service name conflict: {key}"
                )));
            }

            let mut svc = NixService::new(service_name, hostname, zone);
            svc.domain = params.domain.clone();
            svc.title = params.title.clone();
            svc.description = params.description.clone();
            svc.icon = params.icon.clone();
            svc.global = is_global;
            self.services.insert(key, svc);
        }
        Ok(())
    }

    /// Validate and store network configuration from YAML.
    pub fn register_network_config(&mut self, raw: serde_yaml::Value) -> Result<()> {
        // Apply defaults
        let domain = raw
            .get("domain")
            .and_then(|v| v.as_str())
            .unwrap_or(DEFAULT_DOMAIN)
            .to_string();

        let locale = raw
            .get("default")
            .and_then(|d| d.get("locale"))
            .and_then(|v| v.as_str())
            .unwrap_or(DEFAULT_LOCALE)
            .to_string();

        let timezone = raw
            .get("default")
            .and_then(|d| d.get("timezone"))
            .and_then(|v| v.as_str())
            .unwrap_or(DEFAULT_TIMEZONE)
            .to_string();

        let coord_domain = raw
            .get("coordination")
            .and_then(|c| c.get("domain"))
            .and_then(|v| v.as_str())
            .unwrap_or(DEFAULT_COORDINATION_DOMAIN)
            .to_string();

        let coord_hostname = raw
            .get("coordination")
            .and_then(|c| c.get("hostname"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let coord_enable = raw
            .get("coordination")
            .and_then(|c| c.get("enable"))
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        // Validate
        assert_regex(RE_LOCALE, &locale, "Bad default network locale syntax")?;
        assert_regex(
            RE_TIMEZONE,
            &timezone,
            "Bad default network timezone syntax",
        )?;
        if !coord_hostname.is_empty() {
            assert_regex(
                RE_HOSTNAME,
                &coord_hostname,
                "Bad coordination hostname type",
            )?;
        }
        assert_regex(RE_HOSTNAME, &coord_domain, "Bad Headscale domain name")?;

        // SMTP validation
        if let Some(smtp) = raw.get("smtp") {
            if let Some(proto) = smtp.get("protocol").and_then(|v| v.as_str()) {
                assert_regex(RE_SMTP_PROTOCOL, proto, "Bad SMTP protocol")?;
            }
            if let Some(server) = smtp.get("server").and_then(|v| v.as_str()) {
                assert_regex(RE_FQDN, server, "Bad SMTP Server")?;
            }
            if let Some(user) = smtp.get("username").and_then(|v| v.as_str()) {
                assert_email(user, "Bad SMTP Email")?;
            }
        }

        self.config = NetworkConfig {
            domain,
            default_locale: locale,
            default_timezone: timezone,
            coordination_domain: coord_domain,
            coordination_hostname: coord_hostname,
            coordination_enable: coord_enable,
            raw: raw.clone(),
        };

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nix_generator::item::host::ServiceParams;

    #[test]
    fn register_network_config_defaults() {
        let mut net = NixNetwork::default();
        let raw = serde_yaml::from_str("domain: mynet.lan\ncoordination:\n  domain: headscale\n  hostname: hcs\n  enable: false\ndefault:\n  locale: fr_FR.UTF-8\n  timezone: Europe/Paris").unwrap();
        assert!(net.register_network_config(raw).is_ok());
        assert_eq!(net.config.domain, "mynet.lan");
    }

    #[test]
    fn register_network_config_invalid_locale() {
        let mut net = NixNetwork::default();
        let raw = serde_yaml::from_str("domain: x.lan\ncoordination:\n  domain: hcs\n  hostname: h\n  enable: false\ndefault:\n  locale: bad\n  timezone: Europe/Paris").unwrap();
        assert!(net.register_network_config(raw).is_err());
    }

    fn make_service(name: &str, global: bool) -> (String, ServiceParams) {
        (
            name.to_string(),
            ServiceParams {
                title: None,
                description: None,
                domain: None,
                icon: None,
                global,
            },
        )
    }

    #[test]
    fn register_service_conflict_in_zone() {
        let mut net = NixNetwork::default();
        let services1: IndexMap<_, _> = [make_service("nextcloud", false)].into_iter().collect();
        let services2: IndexMap<_, _> = [make_service("nextcloud", false)].into_iter().collect();
        net.register_services("nas1", "lab", &services1).unwrap();
        assert!(net.register_services("nas2", "lab", &services2).is_err());
    }

    #[test]
    fn register_unique_service_per_zone() {
        let mut net = NixNetwork::default();
        let s1: IndexMap<_, _> = [make_service("adguardhome", false)].into_iter().collect();
        let s2: IndexMap<_, _> = [make_service("adguardhome", false)].into_iter().collect();
        net.register_services("dns1", "lab", &s1).unwrap();
        assert!(net.register_services("dns2", "lab", &s2).is_err());
    }

    #[test]
    fn register_global_domain_conflict() {
        let mut net = NixNetwork::default();
        let s1: IndexMap<_, _> = [make_service("auth", true)].into_iter().collect();
        let s2: IndexMap<_, _> = [make_service("auth", true)].into_iter().collect();
        net.register_services("srv1", "lab", &s1).unwrap();
        assert!(net.register_services("srv2", "prod", &s2).is_err());
    }

    #[test]
    fn external_service_implicit_global() {
        let mut net = NixNetwork::default();
        let services: IndexMap<_, _> = [make_service("headscale", false)].into_iter().collect();
        assert!(net
            .register_services("vpn", EXTERNAL_ZONE_KEY, &services)
            .is_ok());
        let svc = net.services().values().next().unwrap();
        assert!(svc.global);
    }
}
