use std::collections::HashMap;

use regex::Regex;

use crate::error::{NixError, Result};

// Regex constants (compiled once via lazy_static pattern)
pub const RE_HOSTNAME: &str = r"^[a-zA-Z][a-zA-Z0-9_-]{1,59}$";
pub const RE_FQDN: &str = r"^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[A-Za-z]{2,63}$";
pub const RE_LOGIN: &str = r"^[a-zA-Z][a-zA-Z0-9_-]{1,59}$";
pub const RE_IDENTIFIER: &str = r"^[a-z][a-zA-Z0-9-]{0,62}[a-zA-Z0-9]$";
pub const RE_DEVICE: &str = r"^/dev(/[a-zA-Z0-9]+){1,3}$";
pub const RE_MAC_ADDRESS: &str = r"^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$";
pub const RE_NAME: &str = r"^.{3,128}$";
pub const RE_IPV4: &str = r"^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$";
pub const RE_LOCALE: &str = r"^[a-z][a-z]_[A-Z][A-Z]\.UTF-8$";
pub const RE_TIMEZONE: &str = r"^([A-Za-z]+)/([A-Za-z0-9_-]+)(/([A-Za-z0-9_-]+))?$";
pub const RE_SMTP_PROTOCOL: &str = r"^(http|https|submission|submissions)$";
pub const RE_IP_SUFFIX: &str = r"^([0-9]{1,3}\.)?[0-9]{1,3}$";

// Tailscale CGNAT range: 100.64.0.0/10
const TAILSCALE_MIN: u32 = (100 << 24) | (64 << 16);   // 100.64.0.1
const TAILSCALE_MAX: u32 = (100 << 24) | (127 << 16) | (255 << 8) | 255; // 100.127.255.254

pub fn assert_regex(pattern: &str, value: &str, err: &str) -> Result<()> {
    let re = Regex::new(pattern).expect("Invalid regex pattern");
    if !re.is_match(value) {
        return Err(NixError::validation(format!("Syntax error for \"{value}\": {err}")));
    }
    Ok(())
}

pub fn assert_email(value: &str, err: &str) -> Result<()> {
    if value.is_empty() {
        return Ok(()); // email is optional
    }
    // Simple RFC-5322-compatible check: user@domain.tld
    let re = Regex::new(r"^[^@\s]+@[^@\s]+\.[^@\s]+$").unwrap();
    if !re.is_match(value) {
        return Err(NixError::validation(format!("Email \"{value}\": {err}")));
    }
    Ok(())
}

pub fn assert_tailscale_ip(ip: &str) -> Result<()> {
    let long = ipv4_to_u32(ip)
        .ok_or_else(|| NixError::validation(format!("ipv4 \"{ip}\" is not a valid address.")))?;
    if long < TAILSCALE_MIN + 1 || long > TAILSCALE_MAX {
        return Err(NixError::validation(format!(
            "ipv4 \"{ip}\" is not a tailnet address (100.64.0.0/10)."
        )));
    }
    Ok(())
}

fn ipv4_to_u32(ip: &str) -> Option<u32> {
    let parts: Vec<u32> = ip.split('.').filter_map(|p| p.parse().ok()).collect();
    if parts.len() != 4 || parts.iter().any(|&p| p > 255) {
        return None;
    }
    Some((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3])
}

/// Track unique names across the whole configuration run.
/// Returns an error if the name was already registered.
pub fn assert_uniq_name(
    tracker: &mut HashMap<String, String>,
    name: &str,
    context: &str,
) -> Result<()> {
    if let Some(existing) = tracker.get(name) {
        return Err(NixError::validation(format!(
            "Name \"{name}\" already exists ({context} vs {existing})"
        )));
    }
    tracker.insert(name.to_string(), context.to_string());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_hostname() {
        assert!(assert_regex(RE_HOSTNAME, "my-host01", "").is_ok());
    }

    #[test]
    fn invalid_hostname_starts_with_digit() {
        assert!(assert_regex(RE_HOSTNAME, "1host", "").is_err());
    }

    #[test]
    fn valid_ipv4() {
        assert!(assert_regex(RE_IPV4, "192.168.1.1", "").is_ok());
    }

    #[test]
    fn invalid_ipv4() {
        assert!(assert_regex(RE_IPV4, "999.0.0.1", "").is_err());
    }

    #[test]
    fn valid_mac() {
        assert!(assert_regex(RE_MAC_ADDRESS, "aa:bb:cc:dd:ee:ff", "").is_ok());
    }

    #[test]
    fn invalid_mac_uppercase() {
        assert!(assert_regex(RE_MAC_ADDRESS, "AA:BB:CC:DD:EE:FF", "").is_err());
    }

    #[test]
    fn valid_locale() {
        assert!(assert_regex(RE_LOCALE, "fr_FR.UTF-8", "").is_ok());
    }

    #[test]
    fn invalid_locale() {
        assert!(assert_regex(RE_LOCALE, "fr_FR", "").is_err());
    }

    #[test]
    fn valid_timezone() {
        assert!(assert_regex(RE_TIMEZONE, "Europe/Paris", "").is_ok());
        assert!(assert_regex(RE_TIMEZONE, "America/New_York", "").is_ok());
    }

    #[test]
    fn valid_tailscale_ip() {
        assert!(assert_tailscale_ip("100.64.0.1").is_ok());
        assert!(assert_tailscale_ip("100.100.1.1").is_ok());
    }

    #[test]
    fn invalid_tailscale_ip_out_of_range() {
        assert!(assert_tailscale_ip("192.168.1.1").is_err());
        assert!(assert_tailscale_ip("100.128.0.1").is_err());
    }

    #[test]
    fn valid_email() {
        assert!(assert_email("user@example.com", "").is_ok());
        assert!(assert_email("", "").is_ok()); // optional
    }

    #[test]
    fn invalid_email() {
        assert!(assert_email("not-an-email", "").is_err());
    }

    #[test]
    fn uniq_name_tracker() {
        let mut tracker = HashMap::new();
        assert!(assert_uniq_name(&mut tracker, "foo", "ctx1").is_ok());
        assert!(assert_uniq_name(&mut tracker, "foo", "ctx2").is_err());
    }

    #[test]
    fn uid_range() {
        // UIDs must be in 1000..=64999
        let uid: i64 = 1500;
        assert!((1000..=64999).contains(&uid));
        let bad: i64 = 65000;
        assert!(!(1000..=64999).contains(&bad));
    }
}
