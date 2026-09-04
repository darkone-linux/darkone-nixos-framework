# DNF sops, passwords and secrets management.
#
# :::danger[Critical module]
# This module is enabled by default in core module.
# It is recommended to keep it enabled and configure it (`just passwd*` commands).
# :::
#
# Wires sops-nix to `usr/secrets/secrets.yaml` and unlocks it with the
# host SSH key (`ssh_host_ed25519_key`) plus the dedicated infrastructure
# age key (`/etc/sops/age/infra.key`). Declares one
# `user/<login>/password-hash` secret per host user, with
# `neededForUsers = true` so the hash is available before the user accounts
# are created.
#
# Nothing else is materialised here: a secret belongs on the hosts that
# consume it, declared by the module that reads it. `default-password-hash`
# stays in the encrypted file, unread by any host — it records the fleet
# default password for `just passwd <login>`.

{
  lib,
  config,
  host,
  workDir,
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

      # Sops configuration
      defaultSopsFile = workDir + "/usr/secrets/secrets.yaml";
      age = {
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = "/etc/sops/age/infra.key";
        generateKey = false; # Key generated manually
      };

      # Users passwords. `neededForUsers` secrets are decrypted before the
      # users exist, so sops-nix rejects `owner`/`group`/`mode` on them —
      # they stay root-owned by construction.
      secrets = builtins.listToAttrs (
        map (login: {
          name = "user/" + login + "/password-hash";
          value = {
            neededForUsers = true;
          };
        }) host.users
      );
    };
  };
}
