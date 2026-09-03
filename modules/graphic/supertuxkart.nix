# SuperTuxKart with configurations to play in local network.
#
# :::tip
# To use in conjonction with homemanager games module!
# :::
#
# :::caution[Zone-scoped firewall]
# Game and discovery ports are accepted from the zone prefix only. A STK host
# that also holds a WAN or tailnet address does not publish the game there.
# :::

{
  lib,
  config,
  dnfLib,
  zone,
  network,
  host,
  hosts,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.supertuxkart;

  # Same resolution as `service/nfs.nix`: the tracks share rides on the zone NFS
  # server. The former hand-rolled lookup aborted evaluation in a zone with no
  # NFS service (`.host` on a `""` sentinel).
  nfs = dnfLib.resolveNfs {
    inherit host hosts zone;
    inherit (network) services;
  };
  isMainNfsServer = config.darkone.service.nfs.enable && nfs.isServer;
  nfsServer = "nfs"; # TODO: find a way to obtain the right service fqdn
  inherit (config.darkone.system) srv-dirs;
  sharePrefix = if cfg.isNfsServer then srv-dirs.nfs else "/mnt/nfs";

  # Exported to the declared `nfs-client` hosts, like every other share of the
  # zone; an empty spec would mean "everyone".
  exportTo = opts: lib.concatMapStringsSep " " (ip: "${ip}(${opts})") nfs.clientIps;
  hasClients = nfs.clientIps != [ ];

  # `service/nfs.nix` already exports the NFSv4 root on the same host; a second
  # identical line only earns an `exportfs` duplicate warning.
  exportsRoot = !config.darkone.service.nfs.enable;

  # The global zone carries no prefix: nothing to anchor a source match on.
  inLocalZone = dnfLib.inLocalZone zone;
  zoneCidr = lib.optionalString inLocalZone "${zone.networkIp}/${toString zone.prefixLength}";
in
{
  options = {
    darkone.graphic.supertuxkart.enable = lib.mkEnableOption "SuperTuxKart + firewall config + tracks share";

    # TODO: force the central NFS server to be the one sharing
    darkone.graphic.supertuxkart.isNfsServer = lib.mkOption {
      type = lib.types.bool;
      default = isMainNfsServer;
      description = "NFS server (share tracks), default is the main NFS server. (wip, enable on main server)";
    };
  };

  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = inLocalZone;
        message = "darkone.graphic.supertuxkart on ${host.hostname}: LAN game, unusable in the global zone (no prefix to scope its firewall rules on).";
      }
    ];

    # STK package
    environment.systemPackages = with pkgs; [ supertuxkart ];

    # NFS Share (server)
    systemd.tmpfiles.rules = [ "d ${sharePrefix}/stk-tracks 0775 nobody users -" ];
    services.nfs.server = lib.mkIf cfg.isNfsServer {
      enable = true;
      exports = lib.optionalString hasClients (
        lib.optionalString exportsRoot ''
          ${srv-dirs.nfs}            ${exportTo "rw,fsid=0,no_subtree_check"}
        ''
        + ''
          ${srv-dirs.nfs}/stk-tracks ${exportTo "ro,nohide,async,no_subtree_check,all_squash,anonuid=65534,anongid=100"}
        ''
      );
    };

    # NFS mount (clients)
    fileSystems."/mnt/nfs/stk-tracks" = lib.mkIf ((!cfg.isNfsServer) && nfs.hasServer) {
      device = "${nfsServer}.${host.zoneDomain}:/stk-tracks";
      fsType = "nfs";
      options = [
        "x-systemd.automount" # Mount on demand
        "x-systemd.idle-timeout=600" # Unmount after 10min with no activity
        "noauto"
        "noatime"
        "ro"
      ];
    };

    # Open ports & accept broadcasts (local servers discovery)
    networking.firewall = {
      enable = true;

      # No `allowedUDPPorts`: it emits no `iifname` and no source match, so the
      # game and its discovery range landed on every leg of the host. Three
      # rules, all anchored on the zone prefix:
      #
      # - 2757 covers the discovery broadcast as well as its unicast form;
      # - 2759 is the game server port;
      # - the ephemeral range receives the discovery answer, which conntrack
      #   cannot relate to a broadcast request.
      extraInputRules = lib.optionalString inLocalZone ''
        ip saddr ${zoneCidr} udp dport { 2757, 2759 } accept
        ip saddr ${zoneCidr} udp dport 32768-60999 accept
      '';
    };
  };
}
