# MicroVM guest side: hypervisor, routed link, shares, persistent host key.

{
  lib,
  config,
  options,
  dnfLib,
  host,
  hosts,
  zone,
  ...
}:
let
  cfg = config.darkone.system.microvm;
  link = dnfLib.mkMicrovmLink host;
  hypervisor = lib.findFirst (h: h.hostname == cfg.hypervisor) { } hosts;
  hostKey = "/persist/ssh/ssh_host_ed25519_key";

  # Activation writes `/var/lib/nixos` and `/home/<login>` before stage 2
  # mounts: a share mounted later would hide them, hence `neededForBoot`.
  share = tag: mountPoint: {
    inherit tag mountPoint;
    source = "${cfg.stateDir}/${host.hostname}/${tag}";
    proto = "virtiofs";
  };
  shares = [
    (share "persist" "/persist")
    (share "var-lib" "/var/lib")
    (share "home" "/home")
  ];
in
{

  # `microvm.*` only exists where mk-configuration imports the guest module.
  config = lib.optionalAttrs (options ? microvm.guest) (
    lib.mkIf (cfg.hypervisor != null) {
      assertions = [
        {
          assertion = hypervisor.zone == host.zone;
          message = "${host.hostname}: microVM guest and hypervisor `${cfg.hypervisor}` must share a zone (routed /32 on its LAN).";
        }
      ];

      microvm = {
        hypervisor = "cloud-hypervisor";
        inherit (cfg.guest) vcpu mem;

        # sd_notify over vsock: `microvm@` turns active once the guest is up,
        # so a deploy reports a guest that fails to boot.
        vsock.cid = link.cid;

        # Writable layer: enables nix-daemon, needed by Home Manager activation
        # and agents' `nix shell`. tmpfs: the Nix db is rebuilt at each boot
        # anyway (upstream caveat), so built paths are lost with it.
        writableStoreOverlay = "/nix/.rw-store";
        interfaces = [
          {
            type = "tap";
            id = link.tap;
            inherit (link) mac;
          }
        ];
        shares = [
          {
            tag = "ro-store";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            proto = "virtiofs";
          }
        ]
        ++ shares;
      };

      fileSystems = lib.listToAttrs (
        map (s: lib.nameValuePair s.mountPoint { neededForBoot = true; }) shares
      );

      # Root is a tmpfs: the host key, hence the sops identity, lives on
      # `/persist`. The infra key never enters a guest: own secrets file only.
      darkone.system.sops.isolated = lib.mkDefault true;

      # Store reset at each boot: optimise is unsupported on the overlay
      # (microvm.nix assertion), GC would only scan the hypervisor's store.
      nix.optimise.automatic = lib.mkForce false;
      nix.gc.automatic = lib.mkForce false;
      services.openssh.hostKeys = [
        {
          path = hostKey;
          type = "ed25519";
        }
      ];
      sops.age.sshKeyPaths = [ hostKey ];

      # Static `/32`, every packet goes through the hypervisor (cf. microvm.nix
      # `routed-network.md`). No DHCP: the zone gateway never sees the guest MAC.
      networking.useNetworkd = true;
      networking.useDHCP = false;
      systemd.network.networks."10-lan" = {
        matchConfig.MACAddress = link.mac;
        address = [ "${host.ip}/32" ];
        routes = [
          { Destination = "${hypervisor.ip}/32"; }
          {
            Gateway = hypervisor.ip;
            GatewayOnLink = true;
          }
        ];
        networkConfig.DNS = [ zone.gateway.lan.ip ];
      };
    }
  );
}
