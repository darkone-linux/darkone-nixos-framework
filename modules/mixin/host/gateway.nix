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
# The profile enables `networking.firewall.filterForward` and states the flows
# a zone router is for: LAN to WAN, and LAN to and from the tailnet. Anything
# else crossing the gateway is dropped. A gateway that must route something
# more appends it to `networking.firewall.extraForwardRules` in its host file.
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

  # The two internal legs of a zone router, from the framework constants and
  # never re-typed: a rule that names an interface by hand is a rule that
  # silently stops matching the day the interface is renamed.
  inherit (dnfLib.constants) lanInterface vpnInterface;

  # Everything opened without an interface, flattened for the assertion below.
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

        # A gateway is the one host of a zone that routes, and routed packets
        # are never seen by the input chain: `allowedTCPPorts` and friends say
        # nothing about them. With `filterForward` at its default NixOS emits
        # no forward chain at all, so the kernel policy applies — ACCEPT, since
        # `networking.nat` turns forwarding on. On a gateway whose WAN holds a
        # public address that is a plain, unfiltered route from the Internet
        # into the zone subnet: anyone able to send packets to the WAN address
        # with a zone destination reaches the LAN, no port forward needed.
        #
        # So we state the flows a zone gateway exists for, and drop the rest.
        # `ct state established,related accept` (replies to outbound traffic)
        # and `ct status dnat accept` (explicit port forwards) are already in
        # the upstream forward chains and are not repeated here.
        #
        # Interface names are matched with `iifname`/`oifname`, which compare
        # strings: a rule may safely name an interface that does not exist yet
        # (no tailnet on a zone without headscale, no bridge before dnsmasq).
        networking.firewall = {

          # mkDefault: a gateway with an unusual topology (a container runtime,
          # a second uplink) can opt out in its host file rather than fight the
          # ruleset — but it then owns the consequence, explicitly.
          filterForward = lib.mkDefault true;

          # Internet sharing (LAN to WAN) is NOT declared here: the NixOS nat
          # module appends its own `iifname { <internal> } oifname <wan>
          # accept` to this very chain as soon as `filterForward` is on, from
          # the `internalInterfaces` / `internalIPs` set in
          # `service/dnsmasq.nix`. Restating it would only add a duplicate
          # rule that later drifts from the one actually in force.
          extraForwardRules = ''
            # Subnet routing, both ways: the tailnet reaches the zone, and the
            # zone reaches the tailnet — hence the other zones, whose routes
            # this gateway accepts. Tailscale advertises the zone subnet with
            # `--snat-subnet-routes=false`, so packets arriving from the
            # tailnet keep their 100.64.0.0/10 source: these two rules are
            # what makes an advertised route usable at all.
            iifname "${vpnInterface}" oifname "${lanInterface}" accept
            iifname "${lanInterface}" oifname "${vpnInterface}" accept

            # In and out of the same bridge. Unreachable as long as
            # br_netfilter stays unloaded (bridged frames never enter the ip
            # forward hook); loaded by a container runtime, it would otherwise
            # start dropping intra-zone traffic that L2 has always forwarded.
            # Stated so the zone does not depend on a module being absent.
            iifname "${lanInterface}" oifname "${lanInterface}" accept
          '';
        };

        # No port is ever "global" on a gateway — only public.
        #
        # `allowedTCPPorts` and friends are emitted without any `iifname`, so
        # on the one host of the zone that holds a WAN address they publish
        # the service on the Internet. Every port a gateway serves must name
        # its interface (`networking.firewall.interfaces.<iface>`), and this
        # assertion is what keeps that true rather than a comment nobody
        # rereads: the 2026-09 audit found the same forgotten rule three
        # times (D1, D2, E3), once hidden for months behind a `mkForce [ ]`
        # in a single host file — which protected that one gateway and left
        # the two others open.
        assertions = [
          {
            assertion = globalPorts == [ ];
            message = ''
              Gateway ${host.hostname} opens ports on every interface, WAN included: ${lib.concatStringsSep ", " globalPorts}.
              Move them under networking.firewall.interfaces.${lanInterface}
              (zone) or .${vpnInterface} (tailnet). A port that really must be
              public belongs on the WAN interface, explicitly and with a
              comment saying why.
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
