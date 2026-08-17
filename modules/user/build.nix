# Build users NixOS (not home-manager) configuration.
#
# :::danger[Required module]
# This module is enabled by default (required by DNF configuration).
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
in
{
  options = {
    darkone.user.build.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Users common builder (enabled by default)";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users = builtins.listToAttrs (map mkUser host.users);

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
