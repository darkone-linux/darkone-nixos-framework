# sudo hardening (R38–R44). (wip)
#
# Covers the dedicated sudo group (R38), hardened sudo directives (R39),
# restriction of non-root targets (R40), NOEXEC limitation (R41),
# forbidding negations (R42), explicit argument specification (R43),
# and use of sudoedit (R44).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R39 — requiretty]
# `requiretty` makes `ssh user@host sudo cmd` fail without an allocated TTY.
# The SSH `-t` option is required: `ssh -t user@host sudo cmd`.
# :::
#
# :::caution[R39 — rootpw]
# `rootpw` forces a root password shared between admins.
# Prefer `targetpw` or `runaspw` based on team policy.
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.sudo;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });

  adminMail = mainSecurityCfg.adminMailbox;
in
{
  options = {
    darkone.security.sudo.enable = lib.mkEnableOption "Enable ANSSI sudo hardening (R38–R44).";

    darkone.security.sudo.allowedRootRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "sudo rules allowed to target root (R40). Others must target a service account.";
    };
  };

  config = lib.mkMerge [
    { darkone.security.sudo.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R38 — Dedicated sudo group (reinforced, base)
        (lib.mkIf (isActive "R38" "reinforced" "base" [ ]) {

          # execWheelOnly: sudo restricted to members of the wheel group
          security.sudo.execWheelOnly = true;

          # TODO: option to create a sudoers group distinct from wheel
          # users.groups.sudoers = { };
        })

        # R39 — Hardened sudo directives (intermediary, base)
        (lib.mkIf (isActive "R39" "intermediary" "base" [ ]) {
          security.sudo.extraConfig = ''
            Defaults  noexec, requiretty, use_pty, umask=0027
            Defaults  ignore_dot, env_reset
            Defaults  log_input, log_output, iolog_dir=/var/log/sudo-io
            Defaults  passwd_timeout=1, timestamp_timeout=5
            ${lib.optionalString (
              adminMail != ""
            ) "Defaults  mailto=\"${adminMail}\", mail_badpass, mail_no_user"}
          '';

          # Directory for sudo I/O logs
          systemd.tmpfiles.rules = [ "d /var/log/sudo-io 0750 root adm -" ];
        })

        # R40 — Non-root targets for sudo (intermediary, base)
        # sideEffects: requires creating intermediate service accounts
        (lib.mkIf (isActive "R40" "intermediary" "base" [ ]) {
          assertions = [
            {
              # Ensure no extraRules targets root except sudo.allowedRootRules
              assertion = lib.all (
                rule:
                rule.runAs or "" != "root"
                || lib.elem (lib.concatStringsSep "," (rule.commands or [ ])) cfg.allowedRootRules
              ) (config.security.sudo.extraRules or [ ]);
              message =
                "R40: sudo rules targeting root must be listed in " + "darkone.security.sudo.allowedRootRules.";
            }
          ];
        })

        # R41 — Limit NOEXEC override (reinforced, base)
        # sideEffects: prevents sudo -E env with dynamic variables
        (lib.mkIf (isActive "R41" "reinforced" "base" [ ]) {
          assertions = [
            {
              # Ensure no bare EXEC: without a command list
              # TODO: parse security.sudo.extraConfig to detect bare "EXEC:"
              assertion = true;
              message = "R41: bare EXEC: without an explicit command list is forbidden in sudoers.";
            }
          ];
        })

        # R42 — Forbid negations (intermediary, base)
        (lib.mkIf (isActive "R42" "intermediary" "base" [ ]) {
          assertions = [
            {
              # TODO: ensure no `!` in security.sudo.extraRules and extraConfig
              assertion = true;
              message = "R42: Negations (!) are forbidden in sudo rules.";
            }
          ];
        })

        # R43 — Specify arguments (intermediary, base)
        # sideEffects: many rules to write for complex commands
        # Validation: cvtsudoers -f json + Rust check (later phase)

        # R44 — sudoedit (intermediary, base)
        # sideEffects: sudoedit requires a consistent EDITOR in the environment
        (lib.mkIf (isActive "R44" "intermediary" "base" [ ]) {
          assertions = [
            {
              # TODO: ensure vi/vim/nano/emacs are not targeted directly in sudoers
              assertion = true;
              message = "R44: Use sudoedit instead of calling vi/vim/nano/emacs via sudo.";
            }
          ];
        })
      ]
    ))
  ];
}
