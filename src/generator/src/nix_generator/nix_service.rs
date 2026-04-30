/// Services that may exist at most once per zone.
pub const UNIQUE_SERVICES_BY_ZONE: &[&str] = &["ncps", "adguardhome", "homepage"];

/// Services accessed via a reverse proxy.
pub const REVERSE_PROXY_SERVICES: &[&str] = &[
    "ai",
    "adguardhome",
    "auth",
    "dex",
    "element",
    "forgejo",
    "home-assistant",
    "homepage",
    "immich",
    "jitsi-meet",
    "keycloak",
    "matrix",
    "mattermost",
    "mealie",
    "monitoring",
    "navidrome",
    "netdata",
    "nextcloud",
    "opencloud",
    "outline",
    "syncthing",
    "turn",
    "users",
    "vaultwarden",
    "docs",
];

/// Services requiring a fixed external IP.
pub const EXTERNAL_ACCESS_SERVICES: &[&str] = &["headscale", "turn"];

#[derive(Debug, Clone)]
pub struct NixService {
    pub name: String,
    pub host: String,
    pub zone: String,
    pub domain: Option<String>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub icon: Option<String>,
    pub global: bool,
}

impl NixService {
    pub fn new(name: impl Into<String>, host: impl Into<String>, zone: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            host: host.into(),
            zone: zone.into(),
            domain: None,
            title: None,
            description: None,
            icon: None,
            global: false,
        }
    }

    /// Return the effective domain label (custom or defaults to name).
    pub fn domain_label(&self) -> &str {
        self.domain.as_deref().unwrap_or(&self.name)
    }

    /// Build the fully-qualified domain name for this service.
    /// `zone_domain`: the zone's domain (e.g. "lab.example.lan")
    /// `network_domain`: the global network domain (e.g. "example.lan")
    pub fn fqdn(&self, zone_domain: &str, network_domain: &str) -> String {
        let label = self.domain_label();
        if self.global {
            format!("{label}.{network_domain}")
        } else {
            format!("{label}.{zone_domain}")
        }
    }

    pub fn to_map(&self) -> Vec<(&'static str, String)> {
        let mut out = vec![
            ("name", self.name.clone()),
            ("host", self.host.clone()),
            ("zone", self.zone.clone()),
            ("global", self.global.to_string()),
        ];
        if let Some(d) = &self.domain {
            out.push(("domain", d.clone()));
        }
        if let Some(t) = &self.title {
            out.push(("title", t.clone()));
        }
        if let Some(d) = &self.description {
            out.push(("description", d.clone()));
        }
        if let Some(i) = &self.icon {
            out.push(("icon", i.clone()));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fqdn_local_service() {
        let svc = NixService::new("nextcloud", "nas", "lab");
        assert_eq!(svc.fqdn("lab.example.lan", "example.lan"), "nextcloud.lab.example.lan");
    }

    #[test]
    fn fqdn_global_service() {
        let mut svc = NixService::new("headscale", "vpn", "lab");
        svc.global = true;
        assert_eq!(svc.fqdn("lab.example.lan", "example.lan"), "headscale.example.lan");
    }

    #[test]
    fn fqdn_custom_domain() {
        let mut svc = NixService::new("auth", "server", "prod");
        svc.domain = Some("sso".to_string());
        assert_eq!(svc.fqdn("prod.example.lan", "example.lan"), "sso.prod.example.lan");
    }

    #[test]
    fn unique_services_list() {
        assert!(UNIQUE_SERVICES_BY_ZONE.contains(&"adguardhome"));
        assert!(!UNIQUE_SERVICES_BY_ZONE.contains(&"nextcloud"));
    }

    #[test]
    fn external_access_services_list() {
        assert!(EXTERNAL_ACCESS_SERVICES.contains(&"headscale"));
    }
}
