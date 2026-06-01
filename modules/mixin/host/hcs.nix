# The main headscale coordination server.
#
# :::tip[A ready-to-use headscale server!]
# The network is configured in `usr/config.yaml` file.
# Additional enabled services (authentication, etc.)
# are automatically configured with consistent network plumbing on your
# global network.
#
# Zsh alias "h" for "headscale".
# :::

{
  lib,
  config,
  dnfConfig,
  dnfLib,
  host,
  ...
}:
let
  cfg = config.darkone.host.hcs;
  profileServicesArgs = {
    profileName = "hcs";
    inherit host;
    inherit (dnfConfig) modules;
  };
in
{
  options = {
    darkone.host.hcs.enable = lib.mkEnableOption "Enable headscale coordination server";
    darkone.host.hcs.enableClient = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable tailscale client on HCS node (recommended to host services)";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Is a server
        darkone.host.server.enable = true;

        darkone.service.tailscale = lib.mkIf cfg.enableClient {
          enable = true;
          isExitNode = true;
        };

        # Zsh aliases
        programs.zsh.shellAliases.h = "sudo headscale";
      }

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
