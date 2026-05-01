use std::fs;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use dnf_generator::generate::Generate;

/// Set up a temporary project root with:
/// - usr/config.yaml (our test fixture)
/// - var/generated/config.yaml (empty overlay)
/// - dnf/home/profiles/{profile}/ for each profile used in the fixture
fn setup_test_root() -> (TempDir, PathBuf) {
    let dir = TempDir::new().unwrap();
    let root = dir.path().to_path_buf();

    // Profile dirs referenced by fixtures/config.yaml (host profiles and user profiles)
    for profile in &[
        "server-profile",
        "gateway-profile",
        "desktop-profile",
        "nix-admin",
        "admin-profile",
        "user-profile",
    ] {
        fs::create_dir_all(root.join("dnf/home/profiles").join(profile)).unwrap();
    }

    // YAML paths
    fs::create_dir_all(root.join("usr")).unwrap();
    fs::create_dir_all(root.join("var/generated")).unwrap();

    fs::write(
        root.join("usr/config.yaml"),
        include_str!("fixtures/config.yaml"),
    )
    .unwrap();
    fs::write(
        root.join("var/generated/config.yaml"),
        include_str!("fixtures/config_generated.yaml"),
    )
    .unwrap();

    (dir, root)
}

fn make_generate(root: &Path) -> Generate {
    let main_yaml = root.join("usr/config.yaml");
    let gen_yaml = root.join("var/generated/config.yaml");
    Generate::new(&main_yaml, &gen_yaml).expect("Generate::new should succeed")
}

// ─── helpers ────────────────────────────────────────────────────────────────

/// Assert the output contains a Nix assignment `key = "value";`
fn assert_str_field(output: &str, key: &str, value: &str) {
    let expected = format!(r#"{key} = "{value}""#);
    assert!(
        output.contains(&expected),
        "Expected `{expected}` in output.\n\nActual output:\n{output}"
    );
}

/// Assert the output contains `key = true;` or `key = false;`
#[allow(dead_code)]
fn assert_bool_field(output: &str, key: &str, value: bool) {
    let expected = format!("{key} = {value};");
    assert!(
        output.contains(&expected),
        "Expected `{expected}` in output.\n\nActual output:\n{output}"
    );
}

/// Assert the output does NOT contain the given fragment.
fn assert_absent(output: &str, fragment: &str) {
    assert!(
        !output.contains(fragment),
        "Expected `{fragment}` to be absent from output.\n\nActual output:\n{output}"
    );
}

// ─── generate_hosts tests ───────────────────────────────────────────────────

#[test]
fn generate_hosts_returns_nix_list() {
    let (_dir, root) = setup_test_root();
    let gen = make_generate(&root);
    let output = gen.generate_hosts_raw().unwrap();

    // Must start with the header comment and then a Nix list
    assert!(output.contains("DO NOT EDIT"), "Missing header comment");
    assert!(
        output.trim_start().contains('['),
        "Output must be a Nix list"
    );
    assert!(output.contains(']'), "Output must close the Nix list");
}

#[test]
fn generate_hosts_has_all_three_hosts() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    assert!(output.contains(r#"hostname = "vps""#), "Missing vps host");
    assert!(output.contains(r#"hostname = "gw""#), "Missing gw host");
    assert!(output.contains(r#"hostname = "ws""#), "Missing ws host");
}

#[test]
fn generate_hosts_preserves_declaration_order() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let pos_vps = output.find(r#"hostname = "vps""#).unwrap();
    let pos_gw = output.find(r#"hostname = "gw""#).unwrap();
    let pos_ws = output.find(r#"hostname = "ws""#).unwrap();

    assert!(pos_vps < pos_gw, "vps must come before gw");
    assert!(pos_gw < pos_ws, "gw must come before ws");
}

// ─── VPS (external zone "www") ───────────────────────────────────────────────

#[test]
fn vps_basic_fields() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    assert_str_field(&output, "hostname", "vps");
    assert_str_field(&output, "zone", "www");
    assert_str_field(&output, "fqdn", "vps.test.lan");
    assert_str_field(&output, "name", "Virtual Private Server");
    assert_str_field(&output, "profile", "server-profile");
    assert_str_field(&output, "ip", "1.2.3.4");
    assert_str_field(&output, "vpnIp", "100.64.0.10");
    assert_str_field(&output, "zoneDomain", "test.lan");
    assert_str_field(&output, "networkDomain", "test.lan");
}

#[test]
fn vps_has_no_groups() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    // The vps block should have an empty groups list.
    // We locate the vps block and check within it.
    let vps_start = output.find(r#"hostname = "vps""#).unwrap();
    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let vps_block = &output[vps_start..gw_start];
    assert!(
        vps_block.contains("groups = [ ]") || vps_block.contains("groups = []"),
        "vps groups must be empty list\n\nvps block:\n{vps_block}"
    );
}

#[test]
fn vps_users_contains_only_nix() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let vps_start = output.find(r#"hostname = "vps""#).unwrap();
    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let vps_block = &output[vps_start..gw_start];

    assert!(
        vps_block.contains(r#""nix""#),
        "vps users must include \"nix\""
    );
    assert!(
        !vps_block.contains(r#""admin""#),
        "vps users must not include \"admin\""
    );
}

#[test]
fn vps_features() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let vps_start = output.find(r#"hostname = "vps""#).unwrap();
    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let vps_block = &output[vps_start..gw_start];

    // Feature "monitoring:local" → monitoring = "local"
    assert!(
        vps_block.contains(r#"monitoring = "local""#),
        "vps features must have monitoring = \"local\"\n\nvps block:\n{vps_block}"
    );
}

#[test]
fn vps_colmena_tags() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let vps_start = output.find(r#"hostname = "vps""#).unwrap();
    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let vps_block = &output[vps_start..gw_start];

    assert!(vps_block.contains(r#""online""#), "Missing tag: online");
    assert!(
        vps_block.contains(r#""feature-monitoring""#),
        "Missing tag: feature-monitoring"
    );
    assert!(vps_block.contains(r#""zone-www""#), "Missing tag: zone-www");
    // nix user must NOT appear in colmena tags
    assert!(
        !vps_block.contains(r#""user-nix""#),
        "user-nix must not be in colmena tags"
    );
}

#[test]
fn vps_services_headscale_empty() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let vps_start = output.find(r#"hostname = "vps""#).unwrap();
    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let vps_block = &output[vps_start..gw_start];

    // headscale has no params → empty attr set
    assert!(
        vps_block.contains("headscale = { }") || vps_block.contains("headscale={ }"),
        "headscale must be an empty attr set\n\nvps block:\n{vps_block}"
    );
}

#[test]
fn vps_services_nextcloud_with_params() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let vps_start = output.find(r#"hostname = "vps""#).unwrap();
    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let vps_block = &output[vps_start..gw_start];

    assert!(
        vps_block.contains(r#"title = "Cloud""#),
        "nextcloud must have title\n\nvps block:\n{vps_block}"
    );
    assert!(
        vps_block.contains(r#"description = "My files""#),
        "nextcloud must have description\n\nvps block:\n{vps_block}"
    );
    assert!(
        vps_block.contains(r#"domain = "cloud""#),
        "nextcloud must have domain\n\nvps block:\n{vps_block}"
    );
    assert!(
        vps_block.contains("global = true"),
        "nextcloud must have global = true\n\nvps block:\n{vps_block}"
    );
}

#[test]
fn vps_services_order_headscale_before_nextcloud() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let vps_start = output.find(r#"hostname = "vps""#).unwrap();
    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let vps_block = &output[vps_start..gw_start];

    let pos_head = vps_block.find("headscale").unwrap();
    let pos_nc = vps_block.find("nextcloud").unwrap();
    assert!(pos_head < pos_nc, "headscale must come before nextcloud");
}

// ─── Gateway (local zone, ip = .1.1) ────────────────────────────────────────

#[test]
fn gw_basic_fields() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    assert_str_field(&output, "fqdn", "gw.local.test.lan");
    assert_str_field(&output, "ip", "10.9.1.1");
    assert_str_field(&output, "zoneDomain", "local.test.lan");
}

#[test]
fn gw_has_no_vpn_ip() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let ws_start = output.find(r#"hostname = "ws""#).unwrap();
    let gw_block = &output[gw_start..ws_start];

    assert_absent(gw_block, "vpnIp");
}

#[test]
fn gw_features_declared_in_order() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let ws_start = output.find(r#"hostname = "ws""#).unwrap();
    let gw_block = &output[gw_start..ws_start];

    // features: ["monitoring", "dns"] → monitoring first, dns second
    let pos_mon = gw_block
        .find(r#"monitoring = "local""#)
        .expect("missing monitoring feature");
    let pos_dns = gw_block
        .find(r#"dns = "local""#)
        .expect("missing dns feature");
    assert!(pos_mon < pos_dns, "monitoring must come before dns");
}

#[test]
fn gw_colmena_tags_include_zone_local() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let ws_start = output.find(r#"hostname = "ws""#).unwrap();
    let gw_block = &output[gw_start..ws_start];

    assert!(gw_block.contains(r#""zone-local""#));
    assert!(gw_block.contains(r#""feature-monitoring""#));
    assert!(gw_block.contains(r#""feature-dns""#));
}

#[test]
fn gw_services_order_adguardhome_before_homepage() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let gw_start = output.find(r#"hostname = "gw""#).unwrap();
    let ws_start = output.find(r#"hostname = "ws""#).unwrap();
    let gw_block = &output[gw_start..ws_start];

    let pos_adg = gw_block.find("adguardhome").unwrap();
    let pos_hp = gw_block.find("homepage").unwrap();
    assert!(pos_adg < pos_hp, "adguardhome must come before homepage");
}

// ─── Workstation (local zone, with groups resolving users) ──────────────────

#[test]
fn ws_basic_fields() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    assert_str_field(&output, "fqdn", "ws.local.test.lan");
    assert_str_field(&output, "ip", "10.9.2.1");
}

#[test]
fn ws_groups() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let ws_start = output.find(r#"hostname = "ws""#).unwrap();
    let ws_block = &output[ws_start..];

    assert!(
        ws_block.contains(r#""staff""#),
        "ws groups must include staff\n\nws block:\n{ws_block}"
    );
}

#[test]
fn ws_users_resolved_from_groups() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let ws_start = output.find(r#"hostname = "ws""#).unwrap();
    let ws_block = &output[ws_start..];

    // Both admin and bob are in group "staff" → must appear in ws users
    assert!(
        ws_block.contains(r#""admin""#),
        "ws users must include admin (from group staff)"
    );
    assert!(
        ws_block.contains(r#""bob""#),
        "ws users must include bob (from group staff)"
    );
    assert!(
        ws_block.contains(r#""nix""#),
        "ws users must always include nix"
    );
}

#[test]
fn ws_users_sorted() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let ws_start = output.find(r#"hostname = "ws""#).unwrap();
    let ws_block = &output[ws_start..];

    // admin < bob < nix (alphabetical order)
    let pos_admin = ws_block.find(r#""admin""#).unwrap();
    let pos_bob = ws_block.find(r#""bob""#).unwrap();
    let pos_nix = ws_block.find(r#""nix""#).unwrap();
    assert!(pos_admin < pos_bob, "admin must come before bob");
    assert!(pos_bob < pos_nix, "bob must come before nix");
}

#[test]
fn ws_colmena_tags_structure() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let ws_start = output.find(r#"hostname = "ws""#).unwrap();
    let ws_block = &output[ws_start..];

    // Tags structure: group-* → feature-* → user-* → zone-*
    assert!(ws_block.contains(r#""group-staff""#));
    assert!(ws_block.contains(r#""feature-nfs-client""#));
    assert!(ws_block.contains(r#""user-admin""#));
    assert!(ws_block.contains(r#""user-bob""#));
    assert!(
        !ws_block.contains(r#""user-nix""#),
        "nix must not be in user-* tags"
    );
    assert!(ws_block.contains(r#""zone-local""#));

    // Order: group before feature before user before zone
    let pos_group = ws_block.find(r#""group-staff""#).unwrap();
    let pos_feat = ws_block.find(r#""feature-nfs-client""#).unwrap();
    let pos_user = ws_block.find(r#""user-admin""#).unwrap();
    let pos_zone = ws_block.find(r#""zone-local""#).unwrap();
    assert!(pos_group < pos_feat);
    assert!(pos_feat < pos_user);
    assert!(pos_user < pos_zone);
}

#[test]
fn ws_services_restic_empty() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_hosts_raw().unwrap();

    let ws_start = output.find(r#"hostname = "ws""#).unwrap();
    let ws_block = &output[ws_start..];

    assert!(
        ws_block.contains("restic = { }") || ws_block.contains("restic={ }"),
        "restic must be an empty attr set\n\nws block:\n{ws_block}"
    );
}
