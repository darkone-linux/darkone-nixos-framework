# Build users NixOS (not home-manager) configuration.
#
# :::danger[Required module]
# This module is enabled by default (required by DNF configuration).
# :::
#
# :::note[SSH denial by logical group]
# `sshDeniedGroups` (default `guests`) expands to `DenyUsers` on each host: a
# member keeps its local session and loses SSH.
# :::

{
  lib,
  config,
  host,
  pkgs,
  users,
  userNixosProfiles,
  ...
}:
let

  # The `user/<login>/password-hash` secrets only exist while the sops module is
  # on. Reading them unconditionally turned `enableSops = false` into an
  # `attribute missing` error pointing here instead of at the flipped option.
  hasSops = config.darkone.system.sops.enable;

  # `userNixosProfiles.<login>` is pre-resolved by `dnf/lib/mkConfigurations.nix`
  # (framework-side or workDir-side NixOS profile path). This module stays
  # agnostic to the framework/consumer layout.
  mkUser =
    login:
    let
      user = users.${login};

      # A user is disabled iff it carries `disabled = true`; absent or false
      # means active (cf. config.yaml).
      disabled = user.disabled or false;

      # Common to every declared account (UID and file ownership preserved
      # even when disabled, cf. R30/R53).
      base = {
        isNormalUser = true;
        inherit (user) uid;
        description = "${user.name}";
      };
    in
    {
      name = login;
      value =

        # Disabled account: neutralised — locked password, no login shell, no
        # credential and no per-user profile (groups, keys, sudo dropped).
        if disabled then
          base
          // {
            hashedPassword = "!";
            shell = "${pkgs.shadow}/bin/nologin";
          }
        else
          base
          // lib.optionalAttrs hasSops {
            hashedPasswordFile = config.sops.secrets."user/${login}/password-hash".path;
          }
          // import userNixosProfiles.${login} {
            inherit
              pkgs
              lib
              config
              login
              ;
          };
    };
  cfg = config.darkone.user.build;

  # `config.yaml` groups are logical (module routing, colmena tags), never
  # materialised as Unix groups: `DenyGroups` would match nothing. The rule
  # stays on the group, only its expansion is computed.
  sshDeniedLogins = lib.filter (
    login: lib.any (group: lib.elem group (users.${login}.groups or [ ])) cfg.sshDeniedGroups
  ) host.users;
in
{
  options = {
    darkone.user.build.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Users common builder (enabled by default)";
    };
    darkone.user.build.sshDeniedGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "guests" ];
      example = [
        "guests"
        "kiosk"
      ];
      description = ''
        Logical groups (`config.yaml`) whose members must never open an SSH
        session. Expanded per host into `services.openssh.settings.DenyUsers`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users = builtins.listToAttrs (map mkUser host.users);

    # Guest accounts exist to open a local session on a shared machine, and
    # share one password: no SSH. `DenyUsers` wins over any `AllowUsers`.
    services.openssh.settings.DenyUsers = lib.mkIf (sshDeniedLogins != [ ]) sshDeniedLogins;

    # sops is the only password source in DNF: without it every declared account
    # would be created without any credential.
    assertions = [
      {
        assertion = hasSops || host.users == [ ];
        message = ''
          darkone.user.build builds ${toString (builtins.length host.users)} account(s) on
          ${host.hostname}, but sops is disabled, so no password hash is available.
          Re-enable darkone.system.core.enableSops, or set
          darkone.user.build.enable = false.
        '';
      }
    ];
  };
}
