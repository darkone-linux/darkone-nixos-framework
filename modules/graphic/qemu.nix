# QEMU test VMs bridged on the DNF LAN
#
# Used by `dnf/scripts/vm-start.sh`.
# Enslaves the wired NIC into a NetworkManager bridge and lets unprivileged
# users plug VMs into it through the setuid `qemu-bridge-helper`. A VM then
# gets its address from the zone gateway like a physical machine, so
# `just full-install <host> nixos <ip>` reaches it.
#
# :::caution[Bridge MAC address]
# `bridge.macAddress` must be the NIC's own MAC: the bridge takes over the host
# IP, and the zone DHCP reservation (`mac` in `etc/config.yaml`) matches on it.
# :::
#
# :::note[Activation]
# Deploying only loads the profiles. Reboot, or `nmcli connection up br0`, to
# move the host IP onto the bridge.
# :::
#
# ```nix
# darkone.graphic.qemu = {
#   enable = true;
#   bridge.interface = "enp2s0";
#   bridge.macAddress = "aa:bb:cc:dd:ee:ff";
# };
# ```

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.qemu;
  portProfile = "${cfg.bridge.name}-${cfg.bridge.interface}";
in
{
  options = {
    darkone.graphic.qemu = {
      enable = lib.mkEnableOption "QEMU test VMs bridged on the DNF LAN";
      bridge = {
        name = lib.mkOption {
          type = lib.types.str;
          default = "br0";
          description = "Bridge interface the VMs plug into.";
        };
        interface = lib.mkOption {
          type = lib.types.str;
          example = "enp2s0";
          description = "Wired NIC enslaved into the bridge.";
        };
        macAddress = lib.mkOption {
          type = lib.types.str;
          example = "aa:bb:cc:dd:ee:ff";
          description = "Bridge MAC address: the NIC's own, to keep the zone DHCP reservation.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = config.networking.networkmanager.enable;
            message = "darkone.graphic.qemu requires networking.networkmanager.enable.";
          }
        ];

        environment.systemPackages = [ pkgs.qemu_kvm ];

        # Keyfiles land in /run and are reloaded, never activated live: the
        # host keeps its link until reboot. Priority 10 beats the stock wired
        # profile at boot.
        networking.networkmanager.ensureProfiles.profiles = {
          ${cfg.bridge.name} = {
            connection = {
              id = cfg.bridge.name;
              type = "bridge";
              interface-name = cfg.bridge.name;
              autoconnect-ports = 1;
              autoconnect-priority = 10;
            };

            # STP off: its listening/learning delay outlasts the DHCP timeout.
            bridge = {
              mac-address = cfg.bridge.macAddress;
              stp = false;
            };
            ipv4.method = "auto";
            ipv6.method = "auto";
          };
          ${portProfile} = {
            connection = {
              id = portProfile;
              type = "ethernet";
              interface-name = cfg.bridge.interface;
              controller = cfg.bridge.name;
              port-type = "bridge";
              autoconnect-priority = 10;
            };
          };
        };
      }

      # libvirtd already owns the helper wrapper and bridge.conf: extend its
      # list, keeping its default `virbr0`.
      (lib.mkIf config.virtualisation.libvirtd.enable {
        virtualisation.libvirtd.allowedBridges = [
          "virbr0"
          cfg.bridge.name
        ];
      })

      # Same two declarations as the upstream libvirtd module, without libvirtd.
      (lib.mkIf (!config.virtualisation.libvirtd.enable) {
        environment.etc."qemu/bridge.conf".text = "allow ${cfg.bridge.name}";
        security.wrappers.qemu-bridge-helper = {
          setuid = true;
          owner = "root";
          group = "root";
          source = "${pkgs.qemu_kvm}/libexec/qemu-bridge-helper";
        };
      })
    ]
  );
}
