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
  mkUser = login: {
    name = login;
    value = {
      isNormalUser = true;
      inherit (users.${login}) uid;
      description = "${users.${login}.name}";
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
