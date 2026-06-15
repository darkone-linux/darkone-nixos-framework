# User accounts and authentication (R30–R36). (wip)
#
# Covers unused accounts (R30), password policy (R31),
# inactivity locking (R32), admin accountability (R33),
# service accounts (R34), unique service accounts (R35),
# and umask (R36).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) activate according to level, category, and
# excludes defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R30 — mutableUsers=false]
# NixOS no longer allows ad-hoc `passwd`/`useradd`. Any account change
# requires a full NixOS deployment (`colmena apply`).
# :::
#
# :::caution[R36 — umask 0077]
# Breaks group collaboration (`/srv/share`). Document that
# `chmod g+rwx <file>` is required for group sharing.
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
  cfg = config.darkone.security.users;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });

  # R30 — locked/empty password hashes do not grant authentication.
  lockedHashes = [
    ""
    "!"
    "*"
    "!!"
  ];

  # A password credential able to open a session (shadow-equivalent of the
  # ANSSI R30 check). SSH-key-only access is out of scope here, matching the
  # spec's /etc/shadow-based control.
  hasPasswordCredential =
    user:
    user.hashedPasswordFile != null
    || user.password != null
    || user.initialPassword != null
    || (user.hashedPassword != null && !(lib.elem user.hashedPassword lockedHashes))
    || (user.initialHashedPassword != null && !(lib.elem user.initialHashedPassword lockedHashes));

  # Human accounts that can actually authenticate. Service/system accounts
  # (isNormalUser = false) and credential-less accounts are out of R30 scope.
  activeNormalUsers = lib.sort (a: b: a < b) (
    lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser && hasPasswordCredential u) config.users.users)
  );

  # Active human accounts missing from the explicit allowlist.
  # The allowlist is the cross-cutting darkone.system.security.allowedActiveUsers.
  r30Offenders = lib.subtractLists mainSecurityCfg.allowedActiveUsers activeNormalUsers;
in
{
  options = {
    darkone.security.users.enable = lib.mkEnableOption "Enable ANSSI account management (R30–R36).";
  };

  config = lib.mkMerge [
    { darkone.security.users.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R30 — Disable unused user accounts (minimal, base)
        # sideEffects: mutableUsers=false prevents ad-hoc passwd/useradd
        (lib.mkIf (isActive "R30" "minimal" "base" [ ]) {

          # DNF already sets this in core.nix; enforced here for standalone use
          users.mutableUsers = lib.mkForce false;

          # mutableUsers=false freezes *which* accounts exist; this assertion
          # checks *which* can open a session: every human account holding a
          # password credential must be explicitly allowlisted.
          assertions = [
            {
              assertion = r30Offenders == [ ];
              message =
                "R30: active user account(s) not allowlisted: "
                + lib.concatStringsSep ", " r30Offenders
                + ". Add them to darkone.system.security.allowedActiveUsers, "
                + "or disable the account (remove its password credential).";
            }
          ];
        })

        # R31 — Strong passwords (minimal, base) — implemented via PAM (R67/R68)
        # sideEffects: enforce_for_root prevents simple reset in rescue
        (lib.mkIf (isActive "R31" "minimal" "base" [ ]) {
          security.pam.services.passwd = {
            rules.password.pwquality = {
              control = "required";
              modulePath = "${pkgs.libpwquality}/lib/security/pam_pwquality.so";

              # Run quality checks just before pam_unix stores the password.
              # Relative offset (not a constant) per the nixpkgs rules guidance.
              order = config.security.pam.services.passwd.rules.password.unix.order - 10;
              settings = {
                minlen = 12;
                minclass = 3;
                maxrepeat = 1;
                enforce_for_root = true;
              };
            };
          };

          # pam_faillock: lock after 3 attempts (see C10)
          security.pam.services.login.failDelay.enable = true;
        })

        # R32 — Inactivity lock (intermediary, base)
        # sideEffects: TMOUT may kill foreground tmux/screen sessions
        (lib.mkIf (isActive "R32" "intermediary" "base" [ ]) {

          # TTY lock: TMOUT set readonly (10 minutes)
          programs.bash.loginShellInit = ''
            readonly TMOUT=600
            export TMOUT
          '';

          # Graphical console: GNOME idle-lock defaults when the DNF GNOME
          # profile is active. Shipped as a non-locked dconf database (own
          # layer, merged with graphic/gnome.nix) so a user may still adjust
          # the delay. Other WMs (Sway, etc.) lock from their home profile.
          programs.dconf.profiles.user.databases = lib.mkIf config.darkone.graphic.gnome.enable [
            {
              settings = {
                "org/gnome/desktop/session".idle-delay = lib.gvariant.mkUint32 600;
                "org/gnome/desktop/screensaver" = {
                  lock-enabled = true;
                  lock-delay = lib.gvariant.mkUint32 0;
                };
              };
            }
          ];
        })

        # R33 — Admin action accountability (intermediary, base)
        # sideEffects: sudo-io logs ~a few MB/day on interactive servers
        (lib.mkIf (isActive "R33" "intermediary" "base" [ ]) {

          # Root disabled (password locked)
          users.users.root.hashedPassword = lib.mkDefault "!";

          # SSH: no direct root login
          services.openssh.settings.PermitRootLogin = lib.mkDefault "no";

          # sudo with I/O logging (see sudo.nix for full config)
          security.sudo.extraConfig = lib.mkDefault ''
            Defaults log_input, log_output, iolog_dir=/var/log/sudo-io
          '';

          # Directory for sudo logs
          systemd.tmpfiles.rules = [ "d /var/log/sudo-io 0750 root adm -" ];
        })

        # R34 — Disable service accounts (intermediary, base)
        # sideEffects: none major, NixOS already compliant by default
        (lib.mkIf (isActive "R34" "intermediary" "base" [ ]) {

          # A service account is "disabled" when it cannot open an interactive
          # session: a non-human account must not BOTH keep a real login shell
          # AND hold a password credential. The credential conjunction (reusing
          # the R30 helper) keeps false positives near zero — almost no system
          # account carries a password.
          assertions =
            let
              hasLoginShell =
                user:
                let
                  s = if user.shell == null then "" else toString user.shell;
                in
                s != "" && !(lib.hasInfix "nologin" s) && !(lib.hasSuffix "/false" s) && !(lib.hasInfix "shadow" s);
              r34Offenders = lib.attrNames (
                lib.filterAttrs (
                  _: u: !u.isNormalUser && hasPasswordCredential u && hasLoginShell u
                ) config.users.users
              );
            in
            [
              {
                assertion = r34Offenders == [ ];
                message =
                  "R34: service account(s) with both a login shell and a password "
                  + "credential: "
                  + lib.concatStringsSep ", " r34Offenders
                  + ". Set shell = nologin/false or remove the password credential.";
              }
            ];
        })

        # R35 — Unique service accounts (intermediary, base)
        # sideEffects: manual migration if a legacy service reuses nobody
        (lib.mkIf (isActive "R35" "intermediary" "base" [ ]) {

          # Assertion: forbid User=nobody in systemd services
          assertions = [
            {
              assertion = lib.all (svc: (svc.serviceConfig or { }).User or "" != "nobody") (
                lib.attrValues config.systemd.services
              );
              message = "R35: The 'nobody' account must not be used as User= in systemd.";
            }
          ];
        })

        # R36 — UMASK (reinforced, base)
        # sideEffects: 0077 breaks group collaboration (/srv/share)
        (lib.mkIf (isActive "R36" "reinforced" "base" [ ]) {

          # Global shell
          environment.etc."profile.d/anssi-umask.sh".text = "umask 0077";

          # PAM: umask on home creation
          security.pam.loginLimits = [
            {
              domain = "*";
              type = "-";
              item = "umask";
              value = "0077";
            }
          ];

          # systemd services: UMask=0027 is part of the R63 hardening baseline
          # (dnfLib.mkHardenedServiceConfig), applied to darkone.security.
          # services.hardenedUnits. Nothing to add here.
        })
      ]
    ))
  ];
}
