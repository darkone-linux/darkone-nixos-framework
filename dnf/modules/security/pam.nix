# PAM — Authentication and password storage (R67–R68). (wip)
#
# Covers secure remote PAM authentication (R67: SSSD, Kerberos, pam_faillock)
# and encrypted password storage (R68: yescrypt).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::note[Complements]
# pam_faillock (anti brute-force) is configured here for R67 and in
# complement.nix (C10). The complexity policy (R31) is in users.nix.
# :::

{
  lib,
  dnfLib,
  config,
  pkgs,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.pam;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.pam.enable = lib.mkEnableOption "Enable ANSSI PAM module — authentication and passwords (R67–R68).";
  };

  config = lib.mkMerge [
    { darkone.security.pam.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R67 — Secure remote PAM authentication (intermediary, base)
        # sideEffects: SSSD requires an additional service and a local cache
        (lib.mkIf (isActive "R67" "intermediary" "base" [ ]) {

          # pam_faillock: anti brute-force locking
          # deny=3: 3 attempts max, unlock_time=900: 15 min lockout
          security.pam.services.login.rules.auth.faillock = {
            control = "required";
            modulePath = "${pkgs.pam}/lib/security/pam_faillock.so";
            settings = {
              preauth = true;
              deny = 3;
              unlock_time = 900;
              even_deny_root = false; # Do not block root (lock-out risk)
            };
          };

          # Assertion: pam_ldap must use TLS if present
          # TODO: verify the nslcd/sssd config if services.sssd.enable or services.nslcd.enable
        })

        # R68 — Encrypted password storage (minimal, base)
        # sideEffects: incompatible with systems lacking yescrypt support (kernels < 5.14)
        (lib.mkIf (isActive "R68" "minimal" "base" [ ]) {
          security.pam.services.passwd.rules.password.unix = {
            control = "sufficient";
            modulePath = "${pkgs.pam}/lib/security/pam_unix.so";
            settings = {
              obscure = true;
              yescrypt = true;
              rounds = 11;
            };
          };

          # login.defs: force yescrypt
          environment.etc."login.defs".text = lib.mkAfter ''
            ENCRYPT_METHOD YESCRYPT
            YESCRYPT_COST_FACTOR 11
          '';
        })
      ]
    ))
  ];
}
