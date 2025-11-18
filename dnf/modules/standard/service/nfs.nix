# NFS server + client for home shares.
#
# :::caution
# This module is auto-enabled if a nfs server is declared in the local network. It creates:
#
# - A share (/export/homes) on the server.
# - Mount dirs (/mnt/nfs/homes/[user]) on clients.
#
# The nfs home manager script links xdg directories to mount dirs.
# :::

{
  lib,
  host,
  pkgs,
  config,
  network,
  ...
}:
let
  cfg = config.darkone.service.nfs;
  isGateway = host.hostname == network.gateway.hostname;
  nfsServerCount = lib.count (s: s.service == "nfs") network.sharedServices;
  nfsServer = (lib.findFirst (s: s.service == "nfs") null network.sharedServices).host;
  isServer = host.hostname == nfsServer;
  isClient = !isServer;
  hasServer = nfsServerCount == 1;
in
assert
  nfsServerCount <= 1
  || builtins.throw "Only one 'nfs' server can be used, found ${toString nfsServerCount}";
{
  options = {
    darkone.service.nfs.enable = lib.mkOption {
      type = lib.types.bool;
      default = hasServer;
      description = "Enable NFS DNF server (avoid enable manually)";
    };
    darkone.service.nfs.serverDomain = lib.mkOption {
      type = lib.types.str;
      default = "nfs";
      description = "NFS Server FQDN";
    };
  };

  config = {

    #--------------------------------------------------------------------------
    # Filesystem requirements (server + client)
    #--------------------------------------------------------------------------

    # Liens symboliques pour chaque utilisateur
    systemd.tmpfiles.rules = lib.optionals isServer (
      [
        "d /export/homes 0755 root root -"
        "d /export/common 0770 nobody users -"
      ]
      ++ map (user: "d /export/homes/${user} 0700 ${user} users -") host.users
      ++ map (user: "d /export/homes/${user}/Documents 0700 ${user} users -") host.users
      ++ map (user: "d /export/homes/${user}/Pictures 0700 ${user} users -") host.users
      ++ map (user: "d /export/homes/${user}/Music 0700 ${user} users -") host.users
      ++ map (user: "d /export/homes/${user}/Videos 0700 ${user} users -") host.users
      ++ map (user: "d /export/homes/${user}/Downloads 0700 ${user} users -") host.users
      ++ map (user: "d /export/homes/${user}/Desktop 0700 ${user} users -") host.users
      ++ map (user: "d /export/homes/${user}/Templates 0700 ${user} users -") host.users
    );

    #--------------------------------------------------------------------------
    # SERVER
    #--------------------------------------------------------------------------

    # Server
    # TODO: IP from network config
    services.nfs.server = lib.mkIf isServer {
      enable = true;
      exports = ''
        /export        192.168.1.0/24(rw,fsid=0,no_subtree_check)
        /export/homes  192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
        /export/common 192.168.1.0/24(rw,nohide,insecure,sync,no_subtree_check,all_squash,anonuid=65534,anongid=100)
      '';
    };

    # Open NFS port, only for lan0 on gateway
    networking.firewall =
      if isGateway then
        { interfaces.lan0.allowedTCPPorts = [ 2049 ]; }
      else
        { allowedTCPPorts = [ 2049 ]; };

    # NFS tools
    environment.systemPackages = [ pkgs.nfs-utils ];

    #--------------------------------------------------------------------------
    # CLIENT
    #--------------------------------------------------------------------------

    # Montage NFS
    fileSystems."/mnt/nfs/homes" = lib.mkIf isClient {
      device = "${cfg.serverDomain}.${network.domain}:/homes";
      fsType = "nfs";
      options = [
        "x-systemd.automount" # Mount on demand
        "x-systemd.idle-timeout=600" # Unmount after 10min with no activity
        "noatime" # Performance
        "rw"
      ];
    };
    fileSystems."/mnt/nfs/common" = lib.mkIf isClient {
      device = "${cfg.serverDomain}.${network.domain}:/common";
      fsType = "nfs";
      options = [
        "x-systemd.automount" # Mount on demand
        "x-systemd.idle-timeout=600" # Unmount after 10min with no activity
        "noatime" # Performance
        "rw"
      ];
    };
  };
}
