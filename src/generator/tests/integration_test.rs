use std::fs;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use dnf_generator::generate::Generate;

/// Set up a temporary project root with:
/// - usr/config.yaml (our test fixture)
/// - var/generated/config.yaml (empty overlay)
/// - dnf/home/profiles/{profile}/ for each profile used in the fixture
/// - dnf/hosts/disko/{profile}.nix for each disko profile in the fixture
/// - dnf/hosts/templates/usr-machines-default.nix
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

    // Disko templates
    fs::create_dir_all(root.join("dnf/hosts/disko")).unwrap();
    fs::write(
        root.join("dnf/hosts/disko/simple.nix"),
        "{ disko.devices.disk.main.device = \"/dev/sda\"; }\n",
    )
    .unwrap();
    // raid profile with mdadm and NEEDEDFORBOOT markers
    fs::write(
        root.join("dnf/hosts/disko/raid.nix"),
        "# NEEDEDFORBOOT:/boot;/nix\n# Raid disko config\n{ disko.devices.disk.disk0.type = \"mdadm\"; }\n",
    )
    .unwrap();

    // Machine default template
    fs::create_dir_all(root.join("dnf/hosts/templates")).unwrap();
    fs::write(
        root.join("dnf/hosts/templates/usr-machines-default.nix"),
        "{ modulesPath, ... }: { imports = [ ./generated-configuration.nix ./hardware-configuration.nix ./disko.nix ]; }\n",
    )
    .unwrap();

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

// ─── generate_users tests ────────────────────────────────────────────────────

#[test]
fn generate_users_returns_nix_attrset() {
    let (_dir, root) = setup_test_root();
    let gen = make_generate(&root);
    let output = gen.generate_users_raw().unwrap();

    assert!(output.contains("DO NOT EDIT"), "Missing header comment");
    // Outer container is a Nix attr set, not a list
    let trimmed = output.trim_start_matches(|c: char| c == '#' || c == '\n' || c == ' ');
    let content = output.trim();
    assert!(
        content.ends_with('}'),
        "Output must end with }} (Nix attr set)\n\nActual:\n{output}"
    );
    let _ = trimmed; // suppress unused warning
}

#[test]
fn generate_users_has_all_users() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    assert!(output.contains("admin"), "Missing admin user");
    assert!(output.contains("bob"), "Missing bob user");
    assert!(output.contains("nix"), "Missing nix user");
}

#[test]
fn generate_users_admin_fields() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    assert_str_field(&output, "email", "admin@test.lan");
    assert_str_field(&output, "name", "Admin User");
    // Profile resolved to dnf/home/profiles/admin-profile
    assert!(
        output.contains(r#"profile = "dnf/home/profiles/admin-profile""#),
        "admin profile path must be resolved\n\nActual:\n{output}"
    );
}

#[test]
fn generate_users_admin_uid() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    assert!(
        output.contains("uid = 1000"),
        "admin uid must be 1000\n\nActual:\n{output}"
    );
}

#[test]
fn generate_users_bob_gets_default_email() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    // bob has no email in YAML → default is login@domain = "bob@test.lan"
    assert_str_field(&output, "email", "bob@test.lan");
}

#[test]
fn generate_users_nix_user_uid() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    // The nix user must appear with uid 65000
    assert!(
        output.contains("uid = 65000"),
        "nix user must have uid 65000\n\nActual:\n{output}"
    );
}

#[test]
fn generate_users_nix_user_profile() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    assert!(
        output.contains(r#"profile = "dnf/home/profiles/nix-admin""#),
        "nix user profile must be nix-admin\n\nActual:\n{output}"
    );
}

#[test]
fn generate_users_nix_user_gets_default_email() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    // nix user has no email in config → default is "nix@test.lan"
    assert_str_field(&output, "email", "nix@test.lan");
}

#[test]
fn generate_users_admin_groups() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    assert!(
        output.contains(r#""staff""#),
        "admin groups must include staff"
    );
    assert!(
        output.contains(r#""admins""#),
        "admin groups must include admins"
    );
}

#[test]
fn generate_users_admin_groups_order() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    // admin has groups: ["staff", "admins"] — staff declared first
    let pos_staff = output.find(r#""staff""#).unwrap();
    let pos_admins = output.find(r#""admins""#).unwrap();
    assert!(
        pos_staff < pos_admins,
        "staff must come before admins (declaration order)"
    );
}

#[test]
fn generate_users_nix_user_has_empty_groups() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_users_raw().unwrap();

    let nix_start = output.find("nix =").unwrap();
    let nix_block = &output[nix_start..];
    assert!(
        nix_block.contains("groups = [ ]") || nix_block.contains("groups = []"),
        "nix user must have empty groups\n\nnix block:\n{nix_block}"
    );
}

// ─── generate_network tests ──────────────────────────────────────────────────

#[test]
fn generate_network_structure() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    assert!(output.contains("DO NOT EDIT"), "Missing header");
    assert!(output.contains("domain"), "Missing domain key");
    assert!(output.contains("services"), "Missing services key");
    assert!(output.contains("zones"), "Missing zones key");
}

#[test]
fn generate_network_domain() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    assert_str_field(&output, "domain", "test.lan");
}

#[test]
fn generate_network_coordination() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // coordination section from fixture: enable=false, hostname="coord", domain="headscale"
    assert!(output.contains("coordination"), "Missing coordination");
    assert_str_field(&output, "hostname", "coord");
    assert_str_field(&output, "domain", "headscale");
}

#[test]
fn generate_network_services_all_present() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // All 5 services from the fixture
    assert!(output.contains(r#"name = "headscale""#), "Missing headscale service");
    assert!(output.contains(r#"name = "nextcloud""#), "Missing nextcloud service");
    assert!(output.contains(r#"name = "adguardhome""#), "Missing adguardhome service");
    assert!(output.contains(r#"name = "homepage""#), "Missing homepage service");
    assert!(output.contains(r#"name = "restic""#), "Missing restic service");
}

#[test]
fn generate_network_service_headscale_fields() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // headscale: global www service, no title/description
    assert!(output.contains(r#"zone = "www""#), "Missing zone www");
    assert!(output.contains(r#"host = "vps""#), "Missing host vps");
    assert!(output.contains("global = true"), "Missing global=true");
}

#[test]
fn generate_network_service_nextcloud_domain() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // nextcloud has domain = "cloud"
    assert_str_field(&output, "domain", "cloud");
    assert_str_field(&output, "title", "Cloud");
    assert_str_field(&output, "description", "My files");
}

#[test]
fn generate_network_service_insertion_order() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // services_as_vec preserves host declaration order (PHP behaviour).
    // Fixture host order: vps (headscale, nextcloud) → gw (adguardhome, homepage) → ws (restic).
    let pos_headscale = output.find(r#"name = "headscale""#).unwrap();
    let pos_adguard = output.find(r#"name = "adguardhome""#).unwrap();
    assert!(
        pos_headscale < pos_adguard,
        "services must follow host insertion order: vps before gw"
    );
}

#[test]
fn generate_network_zones_both_present() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    assert!(output.contains(r#"www = {"#) || output.contains("www ="), "Missing www zone");
    assert!(output.contains(r#"local = {"#) || output.contains("local ="), "Missing local zone");
}

#[test]
fn generate_network_www_zone_config() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // www zone: domain = test.lan (network domain), locale, timezone
    assert_str_field(&output, "locale", "fr_FR.UTF-8");
    assert_str_field(&output, "timezone", "Europe/Paris");
    // www zone name field
    assert!(output.contains(r#"name = "www""#), "www zone must have name = \"www\"");
}

#[test]
fn generate_network_www_gateway_hostname() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // vps is the www gateway (has vpn_ip)
    assert_str_field(&output, "hostname", "vps");
}

#[test]
fn generate_network_local_zone_config() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    assert_str_field(&output, "ipPrefix", "10.9");
    assert_str_field(&output, "networkIp", "10.9.0.0");
    assert!(output.contains("prefixLength = 16"), "Missing prefixLength");
    assert!(output.contains(r#"name = "local""#), "local zone must have name field");
}

#[test]
fn generate_network_local_zone_dhcp_range() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    assert!(
        output.contains("10.9.3.200,10.9.3.249,24h"),
        "Missing DHCP range"
    );
}

#[test]
fn generate_network_local_zone_dhcp_host() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // ws has mac = "aa:bb:cc:dd:ee:ff", ip = 10.9.2.1
    assert!(
        output.contains("aa:bb:cc:dd:ee:ff,10.9.2.1"),
        "Missing DHCP host entry for ws"
    );
}

#[test]
fn generate_network_local_zone_address() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // address = /local.test.lan/10.9.1.1 (gw is the gateway)
    assert!(
        output.contains("/local.test.lan/10.9.1.1"),
        "Missing address entry"
    );
}

#[test]
fn generate_network_local_zone_server_www() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // server forward to www zone via vps vpn_ip
    assert!(
        output.contains("/test.lan/100.64.0.10"),
        "Missing server forward to www zone"
    );
}

#[test]
fn generate_network_local_zone_host_records_hosts() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // All 3 hosts in host-record
    assert!(output.contains("gw.local.test.lan"), "Missing gw host-record");
    assert!(output.contains("ws.local.test.lan"), "Missing ws host-record");
    assert!(output.contains("vps.test.lan"), "Missing vps host-record");
}

#[test]
fn generate_network_local_zone_host_records_services() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // Local zone services (same zone → domain_label alias)
    assert!(
        output.contains("adguardhome.local.test.lan"),
        "Missing adguardhome service record"
    );
    assert!(
        output.contains("homepage.local.test.lan"),
        "Missing homepage service record"
    );
    assert!(
        output.contains("restic.local.test.lan"),
        "Missing restic service record"
    );
    // headscale is EXTERNAL_ACCESS → in local host-record with vps external IP
    assert!(
        output.contains("headscale.test.lan"),
        "Missing headscale external service record"
    );
}

#[test]
fn generate_network_local_zone_headscale_ip() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // headscale (EXTERNAL_ACCESS) → vps external IP = 1.2.3.4
    assert!(
        output.contains("headscale.test.lan,1.2.3.4"),
        "headscale must point to vps external IP"
    );
}

#[test]
fn generate_network_www_tls_builder_hosts() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // tls-builder-hosts: non-global local zone services
    assert!(
        output.contains("adguardhome.local.test.lan"),
        "adguardhome must be in tls-builder-hosts"
    );
    assert!(
        output.contains("homepage.local.test.lan"),
        "homepage must be in tls-builder-hosts"
    );
    assert!(
        output.contains("restic.local.test.lan"),
        "restic must be in tls-builder-hosts"
    );
    // nextcloud is global → not in tls-builder-hosts
    // headscale is in www zone → not in tls-builder-hosts
}

#[test]
fn generate_network_www_unbound_data() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // nextcloud(cloud) is www global, NOT in EXTERNAL_ACCESS → goes in unbound.local-data
    // VPN IP of www zone = vps.vpn_ip = 100.64.0.10
    assert!(
        output.contains("cloud.test.lan. IN A 100.64.0.10"),
        "nextcloud must be in unbound.local-data\n\nActual:\n{output}"
    );
    // headscale is in EXTERNAL_ACCESS → NOT in unbound
}

#[test]
fn generate_network_local_zone_reverse_proxy_uses_gateway_ip() {
    let (_dir, root) = setup_test_root();
    let output = make_generate(&root).generate_network_raw().unwrap();
    // adguardhome and homepage are reverse-proxy services on gw (10.9.1.1)
    assert!(
        output.contains("adguardhome.local.test.lan,10.9.1.1"),
        "adguardhome must use gateway LAN IP"
    );
    assert!(
        output.contains("homepage.local.test.lan,10.9.1.1"),
        "homepage must use gateway LAN IP"
    );
    // restic is NOT a reverse-proxy service on ws (10.9.2.1)
    assert!(
        output.contains("restic.local.test.lan,10.9.2.1"),
        "restic must use actual host IP"
    );
}

// ─── generate_disko tests ────────────────────────────────────────────────────

#[test]
fn generate_disko_creates_machine_dir() {
    let (_dir, root) = setup_test_root();
    make_generate(&root).run("disko").unwrap();
    assert!(
        root.join("usr/machines/vps").is_dir(),
        "vps machine dir must be created"
    );
}

#[test]
fn generate_disko_skips_hosts_without_disko() {
    let (_dir, root) = setup_test_root();
    make_generate(&root).run("disko").unwrap();
    // gw has no disko config → no machine dir created by disko
    assert!(
        !root.join("usr/machines/gw").exists(),
        "gw has no disko, no dir should be created"
    );
}

#[test]
fn generate_disko_copies_default_nix_template() {
    let (_dir, root) = setup_test_root();
    make_generate(&root).run("disko").unwrap();
    let content = fs::read_to_string(root.join("usr/machines/vps/default.nix")).unwrap();
    assert!(
        content.contains("imports"),
        "default.nix must be copied from template"
    );
}

#[test]
fn generate_disko_creates_empty_hardware_configuration() {
    let (_dir, root) = setup_test_root();
    make_generate(&root).run("disko").unwrap();
    let content =
        fs::read_to_string(root.join("usr/machines/vps/hardware-configuration.nix")).unwrap();
    assert_eq!(content.trim(), "{}", "hardware-configuration.nix must be empty attrset");
}

#[test]
fn generate_disko_copies_disko_profile() {
    let (_dir, root) = setup_test_root();
    make_generate(&root).run("disko").unwrap();
    assert!(
        root.join("usr/machines/vps/disko.nix").exists(),
        "disko.nix must be copied"
    );
}

#[test]
fn generate_disko_generated_conf_has_device() {
    let (_dir, root) = setup_test_root();
    make_generate(&root).run("disko").unwrap();
    let content =
        fs::read_to_string(root.join("usr/machines/vps/generated-configuration.nix")).unwrap();
    assert!(
        content.contains("/dev/sda"),
        "generated-configuration.nix must contain device path\n\nActual:\n{content}"
    );
}

#[test]
fn generate_disko_generated_conf_has_header() {
    let (_dir, root) = setup_test_root();
    make_generate(&root).run("disko").unwrap();
    let content =
        fs::read_to_string(root.join("usr/machines/vps/generated-configuration.nix")).unwrap();
    assert!(
        content.contains("DO NOT EDIT"),
        "generated-configuration.nix must have header\n\nActual:\n{content}"
    );
}

#[test]
fn generate_disko_generated_conf_no_swraid_for_simple() {
    let (_dir, root) = setup_test_root();
    make_generate(&root).run("disko").unwrap();
    let content =
        fs::read_to_string(root.join("usr/machines/vps/generated-configuration.nix")).unwrap();
    assert!(
        !content.contains("swraid"),
        "simple profile must not have swraid\n\nActual:\n{content}"
    );
}

#[test]
fn generate_disko_raid_has_swraid_and_neededforboot() {
    let (_dir, root) = setup_test_root();
    make_generate(&root).run("disko").unwrap();
    let content =
        fs::read_to_string(root.join("usr/machines/ws/generated-configuration.nix")).unwrap();
    assert!(
        content.contains("swraid"),
        "raid profile must enable swraid\n\nActual:\n{content}"
    );
    assert!(
        content.contains("neededForBoot"),
        "raid profile must set neededForBoot\n\nActual:\n{content}"
    );
    assert!(
        content.contains("/boot"),
        "raid profile must include /boot partition\n\nActual:\n{content}"
    );
    assert!(
        content.contains("/nix"),
        "raid profile must include /nix partition\n\nActual:\n{content}"
    );
}

#[test]
fn generate_disko_does_not_overwrite_existing_disko_nix() {
    let (_dir, root) = setup_test_root();
    // Pre-create disko.nix with custom content
    fs::create_dir_all(root.join("usr/machines/vps")).unwrap();
    fs::write(
        root.join("usr/machines/vps/disko.nix"),
        "# custom disko",
    )
    .unwrap();
    make_generate(&root).run("disko").unwrap();
    let content = fs::read_to_string(root.join("usr/machines/vps/disko.nix")).unwrap();
    assert_eq!(
        content, "# custom disko",
        "existing disko.nix must not be overwritten"
    );
}

#[test]
fn generate_disko_always_overwrites_generated_configuration() {
    let (_dir, root) = setup_test_root();
    // Pre-create generated-configuration.nix with stale content
    fs::create_dir_all(root.join("usr/machines/vps")).unwrap();
    // Also need disko.nix to exist (since we always read it)
    fs::copy(
        root.join("dnf/hosts/disko/simple.nix"),
        root.join("usr/machines/vps/disko.nix"),
    )
    .unwrap();
    fs::write(
        root.join("usr/machines/vps/generated-configuration.nix"),
        "# stale content",
    )
    .unwrap();
    make_generate(&root).run("disko").unwrap();
    let content =
        fs::read_to_string(root.join("usr/machines/vps/generated-configuration.nix")).unwrap();
    assert!(
        !content.contains("stale"),
        "generated-configuration.nix must be overwritten\n\nActual:\n{content}"
    );
}
