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
          // {
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

  config = lib.mkIf cfg.enable { users.users = builtins.listToAttrs (map mkUser host.users); };
}
