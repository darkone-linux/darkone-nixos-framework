# NFS server + client for home shares.
#
# :::note
# This module is enabled if a nfs server is declared in the local network. It creates:
#
# - A share (/export/homes) on the server.
# - Mount dirs (/mnt/nfs/homes/[user]) on clients.
#
# The nfs home manager script links xdg directories to mount dirs.
# In config.yaml file (hosts):
#
# - Only one host have a service `service.nfs`.
# - Clients need `nfsClient = true`.
# :::

{
  lib,
  host,
  pkgs,
  config,
  zone,
  ...
}:
let
  cfg = config.darkone.service.nfs;
  isGateway =
    lib.attrsets.hasAttrByPath [ "gateway" "hostname" ] zone && host.hostname == zone.gateway.hostname;
  nfsServerCount = lib.count (s: s.service == "nfs") zone.sharedServices;
  nfsServer =
    if nfsServerCount == 0 then
      null
    else
      (lib.findFirst (s: s.service == "nfs") null zone.sharedServices).host;
  isServer = host.hostname == nfsServer;
  hasServer = nfsServerCount == 1;
  isClient = !isServer && hasServer && host.nfsClient;
in
assert
  nfsServerCount <= 1
  || builtins.throw "Only one 'nfs' server can be used, found ${toString nfsServerCount}";
{
  options = {
    darkone.service.nfs.enable = lib.mkOption {
      type = lib.types.bool;
      default = hasServer && (isServer || isClient);
      description = "Enable NFS DNF server (avoid enable manually)";
    };
    darkone.service.nfs.serverDomain = lib.mkOption {
      type = lib.types.str;
      default = "nfs";
      description = "NFS Server FQDN";
    };
  };

  config = lib.mkIf cfg.enable {

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
    services.nfs.server = lib.mkIf isServer {
      enable = true;
      exports = ''
        /export        ${zone.networkIp}/${toString zone.prefixLength}(rw,fsid=0,no_subtree_check)
        /export/homes  ${zone.networkIp}/${toString zone.prefixLength}(rw,sync,no_subtree_check,no_root_squash)
        /export/common ${zone.networkIp}/${toString zone.prefixLength}(rw,nohide,insecure,sync,no_subtree_check,all_squash,anonuid=65534,anongid=100)
      '';
    };

    # Open NFS port, only for lan0 on gateway
    networking.firewall = lib.mkIf isServer (
      if isGateway then
        { interfaces.lan0.allowedTCPPorts = [ 2049 ]; }
      else
        { allowedTCPPorts = [ 2049 ]; }
    );

    # NFS tools
    environment.systemPackages = [ pkgs.nfs-utils ];

    #--------------------------------------------------------------------------
    # CLIENT
    #--------------------------------------------------------------------------

    # NFS Mounts
    fileSystems."/mnt/nfs/homes" = lib.mkIf isClient {
      device = "${cfg.serverDomain}.${host.networkDomain}:/homes";
      fsType = "nfs";
      options = [

        # TODO: automount for laptops?
        # "x-systemd.automount" # Mount on demand
        # "x-systemd.idle-timeout=600" # Unmount after 10min with no activity
        # "noauto" # Required for automount

        "noatime" # Performance
        "hard" # Wait if server do not respond
        "intr" # Ctrl+C to interrupt
        "timeo=600" # 60s timeout
        "retrans=2" # Retry x2
        "_netdev" # Wait the network (implicit)
        "bg" # Background try if fail
        "rw"
      ];
    };
    fileSystems."/mnt/nfs/common" = lib.mkIf isClient {
      device = "${cfg.serverDomain}.${host.networkDomain}:/common";
      fsType = "nfs";
      options = [
        "x-systemd.automount" # Mount on demand
        "x-systemd.idle-timeout=600" # Unmount after 10min with no activity
        "noauto" # Useful with automount
        "noatime" # Performance
        "rw"
      ];
    };

    # Avoid reloads on automounts (force restart)
    systemd.services = lib.mkIf isClient {
      # "mnt-nfs-homes.automount" = {
      #   reloadIfChanged = lib.mkForce false;
      #   restartIfChanged = true;
      # };
      "mnt-nfs-common.automount" = {
        reloadIfChanged = lib.mkForce false;
        restartIfChanged = true;
      };
    };
  };
}
