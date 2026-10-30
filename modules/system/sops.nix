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
# Regular secrets are installed by `sops-install-secrets.service`
# (`sops.useSystemdActivation`), before `sysinit.target`; a changed secret
# restarts its `restartUnits` within the same switch. Password hashes stay
# in the activation script, ahead of the user accounts.
#
# Nothing else is materialised here: a secret belongs on the hosts that
# consume it, declared by the module that reads it.
#
# :::caution[Isolated hosts]
# `isolated = true` (default of the `ai-space` profile) points the host at
# its own `usr/secrets/hosts/<hostname>.yaml`, without the infra key: a host
# running untrusted agents never holds the fleet secrets, and a key an
# earlier install left is deleted. No password hash either, its accounts are
# SSH-key only. Declaring a fleet value there (`luks-passphrase`, a password
# hash, a FIDO2 secret at the fleet salt) fails the eval.
# :::

{
  lib,
  config,
  host,
  workDir,
  ...
}:
let
  cfg = config.darkone.system.sops;
  infraKey = "/etc/sops/age/infra.key";

  # Fleet values an isolated host never declares, by YAML key (aliases
  # included): each opens every disk or account of the fleet.
  fleetKeys = [
    "luks-passphrase"
    "user/[^/]+/password-hash"
    "yubikey/[^/]+/[^/]+/luks-secret"
  ];
  leaks = lib.filter (s: lib.any (p: builtins.match p s.key != null) fleetKeys) (
    lib.attrValues config.sops.secrets
  );
in
{
  options = {
    darkone.system.sops.enable = lib.mkEnableOption "Enable sops automated configuration for DNF";
    darkone.system.sops.isolated = lib.mkEnableOption "own secrets file, no infra key, no password hashes";
  };

  config = lib.mkIf cfg.enable {

    sops = {

      # Secrets from `sops-install-secrets.service`: `restartUnits` go through
      # `systemctl try-restart`. The activation-script path relies on
      # `/run/nixos/activation-restart-list`, removed in NixOS 26.11.
      useSystemdActivation = lib.mkDefault true;

      # Sops configuration
      defaultSopsFile =
        if cfg.isolated then
          workDir + "/usr/secrets/hosts/${host.hostname}.yaml"
        else
          workDir + "/usr/secrets/secrets.yaml";
      age = {

        # `mkDefault`: a microVM guest keeps its host key on a persistent share.
        sshKeyPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = if cfg.isolated then null else infraKey;
        generateKey = false; # Key generated manually
      };

      # Users passwords. `neededForUsers` secrets are decrypted before the
      # users exist, so sops-nix rejects `owner`/`group`/`mode` on them —
      # they stay root-owned by construction.
      secrets = lib.optionalAttrs (!cfg.isolated) (
        builtins.listToAttrs (
          map (login: {
            name = "user/" + login + "/password-hash";
            value = {
              neededForUsers = true;
            };
          }) host.users
        )
      );
    };

    # A host turned isolated keeps the key an earlier install left: tmpfiles
    # `r` deletes it, at boot and on switch. Never on an admin host, which
    # holds the master copy.
    systemd.tmpfiles.rules = lib.mkIf (cfg.isolated && !config.darkone.admin.nix.enable) [
      "r ${infraKey}"
    ];

    # Before the build, which would only report the key missing from the host
    # file: copying it there is the mistake this prevents.
    assertions = [
      {
        assertion = !cfg.isolated || leaks == [ ];
        message = "${host.hostname} is isolated (darkone.system.sops.isolated) and declares fleet secrets: ${
          lib.concatMapStringsSep ", " (s: s.key) leaks
        }. Disable what declares them on this host, never copy them into usr/secrets/hosts/${host.hostname}.yaml.";
      }
    ];
  };
}
