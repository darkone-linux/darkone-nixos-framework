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
    value =
      {
        isNormalUser = true;
        inherit (users.${login}) uid;
        description = "${users.${login}.name}";
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
