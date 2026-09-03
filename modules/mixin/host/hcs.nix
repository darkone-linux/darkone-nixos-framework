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
#
# :::caution[Public SSH]
# This profile opens port 22 on every interface, the Internet included. It is
# the one host of the fleet that does: it runs the tailnet control plane, so
# reaching it must not require the tailnet. Key-only authentication and
# fail2ban are what make that acceptable.
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

        # Public SSH, on purpose.
        #
        # The HCS lives in the global zone: its only leg is the Internet, and
        # `system/core.nix` therefore opens port 22 on the tailnet interface
        # alone. That is not enough here — the tailnet's own control plane
        # runs on this host, so a tailnet-only SSH would lock the
        # administrator out of exactly the incident they need to repair.
        #
        # The exposure is real and stated rather than inherited. What makes it
        # acceptable belongs elsewhere and must stay true: key-only
        # authentication, fail2ban, and the hardening level of the host.
        networking.firewall.allowedTCPPorts = [ 22 ];

        # Zsh aliases
        programs.zsh.shellAliases.h = "sudo headscale";
      }

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
