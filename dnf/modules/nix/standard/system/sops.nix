# DNF sops, passwords and secrets management
#
# :::caution
# This module is enabled by default in core module.
# :::

{
  lib,
  config,
  host,
  ...
}:
let
  cfg = config.darkone.system.sops;
in
{
  options = {
    darkone.system.sops.enable = lib.mkEnableOption "Enable sops automated configuration for DNF";
  };

  config = lib.mkIf cfg.enable {
    sops = {
      defaultSopsFile = ./../../../../../usr/secrets/secrets.yaml;
      age = {
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = "/etc/sops/age/infra.key";
        generateKey = false;
      };

      secrets = {
        default-password = {
          mode = "0440";
          inherit (config.users.users.nobody) group;
        };
        default-password-hash = {
          mode = "0440";
          inherit (config.users.users.nobody) group;
        };
      }
      // builtins.listToAttrs (
        map (login: {
          name = "user/" + login + "/password-hash";
          value = {
            #mode = "0440";
            neededForUsers = true;
            #owner = config.users.users.${login}.name;
            #inherit (config.users.users.nobody) group;
          };
        }) host.users
      );
      #// lib.genAttrs host.users (login: {
      #  mode = "0440";
      #  owner = config.users.users.${login}.name;
      #  inherit (config.users.users.nobody) group;
      #});

    };
  };
}
