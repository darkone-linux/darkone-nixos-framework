# DNF sops, passwords and secrets management.
#
# :::danger[Critical module]
# This module is enabled by default in core module.
# It is recommended to keep it enabled and configure it (`just passwd*` commands).
# :::
#
# Wires sops-nix to `usr/secrets/secrets.yaml` and unlocks it with the
# host SSH key (`ssh_host_ed25519_key`) plus the dedicated infrastructure
# age key (`/etc/sops/age/infra.key`). Pre-declares a shared `sops` group,
# the `default-password` / `default-password-hash` secrets (group-readable
# by `sops`), and one `user/<login>/password-hash` secret per host user
# (with `neededForUsers = true` so the hash is available before the user
# accounts are created).

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

    # unix group for shared passwords
    users.groups.sops = { };

    sops = {

      # Sops configuration
      defaultSopsFile = ./../../../../usr/secrets/secrets.yaml;
      age = {
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = "/etc/sops/age/infra.key";
        generateKey = false; # Key generated manually
      };

      # The common default password
      secrets = {
        default-password = {
          mode = "0440";
          group = "sops";
        };
        default-password-hash = {
          mode = "0440";
          group = "sops";
        };
      }
      //

        # Users passwords
        builtins.listToAttrs (
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
