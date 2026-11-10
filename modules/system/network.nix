# Fleet-wide network configuration of DNF hosts.
#
# Sets up, on every host:
# - the hostname;
# - the nftables firewall (`darkone.system.core.enableFirewall`);
# - SSH opened per role (below).
#
# :::caution[SSH is opened per interface]
# Port 22 is global only on hosts with no WAN leg. A gateway gets it on the LAN
# bridge and the tailnet; a global-zone host on the tailnet only — a public SSH
# there is decided in the host profile.
# :::
#
# #### Software switch (`darkone.system.network.switch`)
#
# Bridges spare NICs with the uplink: a host plugged into a downlink sits in
# the zone as behind an unmanaged hardware switch (DHCP and DNS of the zone
# gateway, nothing to configure on its side).
#
# ```nix
# darkone.system.network.switch = {
#   enable = true;
#   uplink = "enp1s0f1";
#   downlinks = [
#     "enp1s0f0" # 10 GbE
#     "enp2s0"
#   ];
# };
# ```
#
# - bridge `br0` holds the host address (DHCP) with the uplink MAC;
# - pure L2: no STP, no `br_netfilter`, so bridged frames skip nftables;
# - same bridge in the initrd: downlinks keep the network while the host waits
#   for its LUKS unlock, and the address never changes interface at switch-root;
# - systemd-networkd is forced; a zone gateway or a NetworkManager host is refused.
#
# :::caution[One MAC in `config.yaml`]
# The host's `mac` must hold a single address, the uplink's: the bridge takes
# it, so the zone DHCP reservation follows the bridge. Asserted at evaluation.
# :::
#
# :::caution[Deploy with `boot`]
# `just apply <host> boot`, then reboot: a `switch` moves the uplink into the
# bridge mid-activation and drops the SSH session.
# :::

{
  lib,
  config,
  dnfLib,
  host,
  zone,
  ...
}:
let
  coreCfg = config.darkone.system.core;
  cfg = config.darkone.system.network;
  inherit (dnfLib.constants) lanInterface vpnInterface;

  # SSH exposure, per role. `allowedTCPPorts` carries no `iifname`: on a host
  # that also holds a WAN address it publishes sshd on the Internet. Two such
  # roles — the gateway of a local zone, any host of the global zone.
  isZoneGateway = dnfLib.isGateway host zone;
  hasWanInterface = isZoneGateway || !(dnfLib.inLocalZone zone);

  # From the sshd module, so a moved SSH port keeps a matching firewall.
  sshPorts = config.services.openssh.ports;

  # Software switch.
  bridge = "br0";
  hostMacs = dnfLib.getReservedMacs zone host.ip;
  ports = [ cfg.switch.uplink ] ++ cfg.switch.downlinks;

  # networkd units of the switch, shared by the initrd and the system.
  switchNetwork = {
    netdevs."10-${bridge}" = {

      # Uplink MAC: the zone DHCP reservation, hence the host IP, follows the
      # bridge. Without it networkd derives one from the machine-id.
      netdevConfig = {
        Kind = "bridge";
        Name = bridge;
        MACAddress = lib.head hostMacs;
      };

      # Unmanaged switch: two ports cabled to one segment make a loop.
      bridgeConfig.STP = false;
    };

    networks = {

      # Address-less ports. An empty port must not hold wait-online: only the
      # bridge counts.
      "30-${bridge}-ports" = {
        matchConfig.Name = ports;
        networkConfig.Bridge = bridge;
        linkConfig.RequiredForOnline = "no";
      };

      # What `99-ethernet-default-dhcp` gave the uplink: its `Kind = "!*"`
      # leaves the bridge out.
      "40-${bridge}" = {
        matchConfig.Name = bridge;
        DHCP = "yes";
        networkConfig.IPv6PrivacyExtensions = "kernel";
      };
    };
  };
in
{
  options.darkone.system.network.switch = {
    enable = lib.mkEnableOption "the software switch: spare NICs bridged with the uplink into the host's zone";
    uplink = lib.mkOption {
      type = lib.types.str;
      example = "enp1s0f1";
      description = "Interface linked to the zone. Its MAC must be the only `mac` of the host in `config.yaml`.";
    };
    downlinks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "enp1s0f0"
        "enp2s0"
      ];
      description = "Interfaces bridged with the uplink.";
    };
  };

  config = lib.mkMerge [

    # Part of the core: off with `darkone.system.core.enable`.
    (lib.mkIf coreCfg.enable {
      networking = {
        hostName = host.hostname;
        nftables.enable = true;
        firewall = {
          enable = coreCfg.enableFirewall;
          allowPing = lib.mkDefault true;

          # Single-legged host: global and per-interface emit the same rule.
          allowedTCPPorts = lib.optionals (!hasWanInterface) sshPorts;

          # WAN leg: name the interface, and only that one. A gateway gets its
          # zone and the tailnet; a global-zone host has only the tailnet, and
          # declares any public SSH in its own profile.
          interfaces = lib.mkIf hasWanInterface (
            lib.optionalAttrs isZoneGateway { ${lanInterface}.allowedTCPPorts = sshPorts; }
            // lib.optionalAttrs config.services.tailscale.enable {
              ${vpnInterface}.allowedTCPPorts = sshPorts;
            }
          );
        };
      };
    })

    (lib.mkIf cfg.switch.enable {
      assertions = [
        {
          assertion = lib.length hostMacs == 1;
          message =
            "${host.hostname}: darkone.system.network.switch needs exactly one `mac` "
            + "for this host in etc/config.yaml, the MAC of the uplink (${cfg.switch.uplink}). "
            + "The bridge takes it, so the zone DHCP reservation and the host IP follow the bridge. "
            + "Found: ${if hostMacs == [ ] then "none" else lib.concatStringsSep ", " hostMacs}.";
        }
        {
          assertion = !(lib.elem cfg.switch.uplink cfg.switch.downlinks);
          message = "${host.hostname}: switch uplink `${cfg.switch.uplink}` is also a downlink.";
        }
        {
          assertion = !isZoneGateway;
          message = "${host.hostname}: a zone gateway cannot be a switch, its LAN ports already form `${lanInterface}` (gateway.lan.interfaces in etc/config.yaml).";
        }
        {
          assertion = !config.networking.networkmanager.enable;
          message = "${host.hostname}: darkone.system.network.switch runs on systemd-networkd, without NetworkManager.";
        }
      ];

      networking.useNetworkd = true;
      systemd.network = switchNetwork;

      # Inert without the initrd networkd (no LUKS remote unlock); `30-` sorts
      # before `99-dnf-initrd`, the DHCP on `en*` of `system/luks.nix`.
      boot.initrd.systemd.network = switchNetwork;
    })
  ];
}
