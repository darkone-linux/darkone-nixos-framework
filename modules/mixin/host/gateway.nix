# The main gateway / router of a local network zone.
#
# :::tip[A ready-to-use gateway!]
# The gateway is configured in `usr/config.yaml` file.
# Additional enabled services (homepage, adguardhome, forgejo, nix-cache...)
# are automatically configured with consistent network plumbing on the
# gateway and all machines on the local network.
# :::

{
  lib,
  config,
  dnfConfig,
  dnfLib,
  network,
  host,
  ...
}:
let
  cfg = config.darkone.host.gateway;
  hasHeadscale = network.coordination.enable;
  hasAdguardHome = config.darkone.service.adguardhome.enable;
  profileServicesArgs = {
    profileName = "gateway";
    inherit host;
    inherit (dnfConfig) modules;
  };
in
{
  options = {
    darkone.host.gateway.enable = lib.mkEnableOption "Enable gateway features for the current host (dhcp, dns, proxy, etc.)";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        darkone.host.server.enable = true;

        # Gateways usually live on small root partitions and rebuild often:
        # keep only the last system generations instead of 30 days of history.
        darkone.system.core.gcKeepGenerations = lib.mkDefault 5;

        # Tailscale as a VPN gateway when headscale coordination is active.
        darkone.service.tailscale = lib.mkIf hasHeadscale {
          enable = true;
          isGateway = true;
          isExitNode = true;
        };

        #--------------------------------------------------------------------------
        # dnsmasq updates
        #--------------------------------------------------------------------------

        # If headscale is enabled but not adguardhome, we must have fallback DNS
        # servers to contact headscale coordination server. (wip)
        services.dnsmasq.settings = lib.mkIf (hasHeadscale && (!hasAdguardHome)) {

          # no-resolv is false because tailscale client updates the resolv file.
          no-resolv = false;

          # DNS upstreams are headscale DNS upstreams.
          server = config.services.headscale.settings.dns.nameservers.global;
        };
      }

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
