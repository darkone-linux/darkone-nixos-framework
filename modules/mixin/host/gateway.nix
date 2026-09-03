# The main gateway / router of a local network zone.
#
# :::tip[A ready-to-use gateway!]
# The gateway is configured in `usr/config.yaml` file.
# Additional enabled services (homepage, adguardhome, forgejo, nix-cache...)
# are automatically configured with consistent network plumbing on the
# gateway and all machines on the local network.
# :::
#
# :::caution[Routed traffic is filtered]
# `filterForward = true`: only LAN <-> WAN and LAN <-> tailnet cross. Anything
# else is dropped — add it to `networking.firewall.extraForwardRules`.
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

  # Never re-type an interface name: a hand-written one stops matching silently.
  inherit (dnfLib.constants) lanInterface vpnInterface;

  # Ports opened with no iifname, flattened for the assertion below.
  fw = config.networking.firewall;
  globalPorts =
    map (p: "tcp/${toString p}") fw.allowedTCPPorts
    ++ map (r: "tcp/${toString r.from}-${toString r.to}") fw.allowedTCPPortRanges
    ++ map (p: "udp/${toString p}") fw.allowedUDPPorts
    ++ map (r: "udp/${toString r.from}-${toString r.to}") fw.allowedUDPPortRanges;
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

        # Headless: a Nerd font on the TTY buys nothing, and kmscon is a known
        # CPU hog when its console goes stale. Plain getty is enough.
        darkone.system.core.enableKmscon = lib.mkDefault false;

        # Tailscale as a VPN gateway when headscale coordination is active.
        # Subnet router only: exit-node stays opt-in per host. Advertising it
        # here conflicted with `--snat-subnet-routes=false` (needed for clean
        # subnet source IPs) and only produced a permanent health warning.
        darkone.service.tailscale = lib.mkIf hasHeadscale {
          enable = true;
          isGateway = true;
        };

        #--------------------------------------------------------------------------
        # Routed traffic (forward chain)
        #--------------------------------------------------------------------------

        # Routed packets bypass the input chain, and without `filterForward`
        # there is no forward chain at all: kernel policy ACCEPT, i.e. an open
        # route Internet -> zone subnet on a gateway with a public WAN.
        #
        # `established,related` and `ct status dnat` (port forwards) come from
        # the upstream chains. `iifname` matches a string, so a rule may name
        # an interface that does not exist yet.
        networking.firewall = {

          # mkDefault: an unusual gateway (container runtime, second uplink)
          # opts out in its host file, and owns the consequence.
          filterForward = lib.mkDefault true;

          # LAN -> WAN is absent on purpose: the nat module appends its own
          # rules to this chain, from the internalInterfaces / internalIPs set
          # in `service/dnsmasq.nix`.
          extraForwardRules = ''
            # Subnet routing. `--snat-subnet-routes=false` keeps the tailnet
            # source IP, so without these an advertised route is unusable.
            iifname "${vpnInterface}" oifname "${lanInterface}" accept
            iifname "${lanInterface}" oifname "${vpnInterface}" accept

            # Only reached if br_netfilter gets loaded (container runtime);
            # it would then drop what L2 forwards anyway.
            iifname "${lanInterface}" oifname "${lanInterface}" accept
          '';
        };

        # No port is global on a gateway, only public: a rule without
        # `iifname` lands on the WAN. The 2026-09 audit found that same slip
        # three times, once masked by a `mkForce [ ]` in one host file.
        assertions = [
          {
            assertion = globalPorts == [ ];
            message = ''
              Gateway ${host.hostname} opens ports on every interface, WAN included: ${lib.concatStringsSep ", " globalPorts}.
              Move them under networking.firewall.interfaces.${lanInterface}
              (zone) or .${vpnInterface} (tailnet); a deliberately public port
              goes on the WAN interface, with a comment saying why.
            '';
          }
        ];

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
