# Build users from DNF configuration.
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
  ...
}:
let
  mkUser = login: {
    name = login;
    value = {
      isNormalUser = true;
      inherit (users.${login}) uid;
      description = "${users.${login}.name}";
      hashedPasswordFile = config.sops.secrets."user/${login}/password-hash".path;
      #hashedPasswordFile =
      #  if config.sops.secrets ? user && config.sops.secrets.user ? ${login} then
      #    config.sops.secrets.user.${login}.password-hash.path
      #  else
      #    config.sops.secrets.default-password-hash.path;
    }
    // import ./../../../../../${users.${login}.profile}.nix {
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
