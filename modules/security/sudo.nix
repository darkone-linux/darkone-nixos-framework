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
# :::caution[R39 — `noexec` and `requiretty` dropped]
# Both are incompatible with an agent-driven deployment: colmena escalates
# with `sudo -H --` over SSH (no PTY, so `requiretty` refuses), and
# `switch-to-configuration` spawns children (so `noexec` blocks it).
# Accountability rests on `use_pty` + `log_input`/`log_output` instead.
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

  # Single owner of the sudo I/O log path: R33 (users.nix) and R50
  # (filesystem.nix) used to declare it too, yielding duplicate tmpfiles rules.
  ioLogDir = "/var/log/sudo-io";

  # sudoers introspection (R40, R42, R44). A command entry is either a bare
  # string or a `{ command, options }` submodule; normalise both to strings.
  extraRules = config.security.sudo.extraRules or [ ];
  extraConfig = config.security.sudo.extraConfig or "";
  ruleCommandStrings =
    rule: map (c: if lib.isString c then c else c.command or "") (rule.commands or [ ]);
  allCommandStrings = lib.concatMap ruleCommandStrings extraRules;
  allRunAs = map (rule: toString (rule.runAs or "")) extraRules;

  # Direct invocation of an interactive editor via sudo bypasses sudoedit (R44).
  editors = [
    "vi"
    "vim"
    "nvim"
    "view"
    "nano"
    "emacs"
    "ed"
    "pico"
    "joe"
  ];
  firstToken = c: lib.head (lib.splitString " " c);
  commandBaseName = c: lib.last (lib.splitString "/" (firstToken c));
  isEditorCmd = c: c != "" && lib.elem (commandBaseName c) editors;
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
        # sideEffects: iolog_dir writes a few MB/day on interactive servers
        (lib.mkIf (isActive "R39" "intermediary" "base" [ ]) {

          # `noexec` and `requiretty` are deliberately absent — cf. the header:
          # they break colmena and `nixos-rebuild`. `use_pty` keeps the session
          # capture that R39 is really after.
          security.sudo.extraConfig = ''
            Defaults  use_pty, umask=0027
            Defaults  ignore_dot, env_reset
            Defaults  log_input, log_output, iolog_dir=${ioLogDir}
            Defaults  passwd_timeout=1, timestamp_timeout=5
            ${lib.optionalString (
              adminMail != ""
            ) "Defaults  mailto=\"${adminMail}\", mail_badpass, mail_no_user"}
          '';

          systemd.tmpfiles.rules = [ "d ${ioLogDir} 0750 root adm -" ];

          # Session captures grow unbounded; sudo names each one after a
          # sequence, so age is the only usable rotation criterion.
          services.logrotate.settings.sudo-io = {
            files = "${ioLogDir}/*/*/*/log";
            frequency = "weekly";
            rotate = 12;
            compress = true;
            missingok = true;
            notifempty = true;
          };
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
                || lib.elem (lib.concatStringsSep "," (ruleCommandStrings rule)) cfg.allowedRootRules
              ) extraRules;
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
              # Negations defeat exhaustive allowlists: reject `!` in raw config,
              # in command specs and in runAs targets.
              assertion =
                !(lib.hasInfix "!" extraConfig)
                && lib.all (c: !(lib.hasInfix "!" c)) (allCommandStrings ++ allRunAs);
              message = "R42: Negations (!) are forbidden in sudo rules; use an exhaustive allowlist.";
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
              # Best-effort: reject a command whose basename is an interactive
              # editor. Deeper parsing (cvtsudoers -f json) is checkScript work.
              assertion = !(lib.any isEditorCmd allCommandStrings);
              message = "R44: Use sudoedit instead of calling vi/vim/nano/emacs via sudo.";
            }
          ];
        })
      ]
    ))
  ];
}
