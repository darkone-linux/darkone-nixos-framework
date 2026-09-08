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
# pam_faillock (anti brute-force) is configured here for R67; complement.nix
# (C10) only sets session limits. The complexity policy (R31) is in users.nix.
# :::
#
# :::danger[R67 — pam_faillock locks accounts for real]
# Three failed passwords lock the account for 15 minutes by default, on
# `login`, `su`, `sudo` and — through the `login` substack — the GNOME
# greeter. Keep a root session open when first deploying it, and know the way
# back: `faillock --user <login> --reset`. SSH is deliberately spared so that
# a key-based rescue session always stays open.
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

  faillockModule = "${pkgs.pam}/lib/security/pam_faillock.so";
  faillockSettings = {
    inherit (cfg.faillock) deny;
    unlock_time = cfg.faillock.unlockTime;

    # Root stays reachable: it is the way back from a lock-out.
    even_deny_root = false;
  };

  # Stacks that actually gate a password. Derived from the services' own
  # `enable` flags, never from `security.pam.services` itself — reading an
  # option this block also defines would recurse.
  #
  # - `sshd` stays out: DNF forbids password authentication, so faillock can
  #   never count there — it could only refuse a key-based rescue session for
  #   a lock earned on the console.
  # - `gdm-password` stays out: it substacks `login`, and a second pair would
  #   count every failure twice (lock-out at 2 attempts, not `deny`).
  faillockServices = [
    "login"
    "su"
  ]
  ++ lib.optional config.security.sudo.enable "sudo";

  # faillock must bracket the stack's own `pam_unix`: `preauth` refuses just
  # before the credential is checked, `authfail` counts just after. The order
  # differs per service (11700 on su/sudo, 13100 on login), so hardcoding it
  # pushed both rules past `pam_deny` on every stack but `login`.
  unixAuthOrder = service: config.security.pam.services.${service}.rules.auth.unix.order;
in
{
  options = {
    darkone.security.pam.enable = lib.mkEnableOption "Enable ANSSI PAM module — authentication and passwords (R67–R68).";

    darkone.security.pam.faillock.deny = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Failed attempts before pam_faillock locks the account (R67).";
    };

    darkone.security.pam.faillock.unlockTime = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "Seconds an account stays locked (R67). Unlock early with `faillock --reset`.";
    };
  };

  config = lib.mkMerge [
    { darkone.security.pam.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R67 — Secure remote PAM authentication (intermediary, base)
        # sideEffects: a locked-out admin needs `faillock --reset` from root
        (lib.mkIf (isActive "R67" "intermediary" "base" [ ]) {

          # A faillock stack needs all three rules: `preauth` counts, `authfail`
          # denies, and the account rule refuses an already-locked user. The
          # lone `preauth` rule shipped before counted and never locked.
          security.pam.services = lib.genAttrs faillockServices (service: {
            rules = {
              auth.faillock-preauth = {
                control = "required";
                modulePath = faillockModule;
                order = unixAuthOrder service - 50;
                settings = faillockSettings // {
                  preauth = true;
                };
              };

              auth.faillock-authfail = {
                control = "[default=die]";
                modulePath = faillockModule;
                order = unixAuthOrder service + 50;
                settings = faillockSettings // {
                  authfail = true;
                };
              };

              account.faillock = {
                control = "required";
                modulePath = faillockModule;
                order = 10050;
              };
            };
          });

          # Remote PAM/LDAP TLS enforcement is deferred: DNF does not ship a
          # remote directory (no SSSD/nslcd), so there is nothing to validate
          # here yet. The planned direction is Kanidm + PAM (see nss.nix). When
          # a remote backend lands, the TLS check belongs in the checkScript,
          # which can parse the raw sssd/nslcd config (ssl=on, tls_reqcert).
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

          # login.defs: force yescrypt via the canonical loginDefs API.
          # (programs/shadow.nix owns /etc/login.defs; writing environment.etc
          # directly would conflict on the .source/.text of that entry.)
          security.loginDefs.settings = {
            ENCRYPT_METHOD = "YESCRYPT";
            YESCRYPT_COST_FACTOR = 11;
          };
        })
      ]
    ))
  ];
}
