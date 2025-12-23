# NFS server + client for home shares.
#
# :::note
# This module is enabled if a nfs server is declared in the local network. It creates:
#
# - A share (srv-dirs.homes) on the server.
# - Mount dirs (/mnt/nfs/homes/[user]) on clients.
#
# The nfs home manager script links xdg directories to mount dirs.
# In config.yaml file (hosts):
#
# - Only one host have a service `service.nfs`.
# - Clients need `features = [ "nfs-client" ]`.
# :::

{
  lib,
  host,
  pkgs,
  config,
  zone,
  network,
  ...
}:
let

  # TODO: clients dont les serveurs ne sont pas dans la même zone (host.features.nfs-client -> zone externe)
  cfg = config.darkone.service.nfs;
  isGateway =
    lib.attrsets.hasAttrByPath [ "gateway" "hostname" ] zone && host.hostname == zone.gateway.hostname;
  nfsServerCount = lib.count (s: s.name == "nfs" && s.zone == zone.name) network.services;
  nfsServer = (lib.findFirst (s: s.name == "nfs" && s.zone == zone.name) "" network.services).host;
  isServer = host.hostname == nfsServer;
  hasServer = nfsServerCount == 1;
  isClient = !isServer && hasServer && lib.hasAttr "nfs-client" host.features;
  inherit (config.darkone.system) srv-dirs; # Read only
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

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.nfs = {
        displayOnHomepage = false;
        persist = {
          dirs = lib.optionals isServer [
            srv-dirs.homes
            srv-dirs.common
          ];
        };
        proxy.enable = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.nfs.enable = true;
      };

      #--------------------------------------------------------------------------
      # Filesystem requirements (server + client)
      #--------------------------------------------------------------------------

      # Enable shared homes + common dirs
      darkone.system.srv-dirs.enableNfs = isServer;

      # Liens symboliques pour chaque utilisateur
      systemd.tmpfiles.rules = lib.optionals isServer (
        map (user: "d ${srv-dirs.homes}/${user} 0700 ${user} users -") host.users
        ++ map (user: "d ${srv-dirs.homes}/${user}/Documents 0700 ${user} users -") host.users
        ++ map (user: "d ${srv-dirs.homes}/${user}/Pictures 0700 ${user} users -") host.users
        ++ map (user: "d ${srv-dirs.homes}/${user}/Music 0700 ${user} users -") host.users
        ++ map (user: "d ${srv-dirs.homes}/${user}/Videos 0700 ${user} users -") host.users
        ++ map (user: "d ${srv-dirs.homes}/${user}/Downloads 0700 ${user} users -") host.users
        ++ map (user: "d ${srv-dirs.homes}/${user}/Desktop 0700 ${user} users -") host.users
        ++ map (user: "d ${srv-dirs.homes}/${user}/Templates 0700 ${user} users -") host.users
      );

      #--------------------------------------------------------------------------
      # SERVER
      #--------------------------------------------------------------------------

      # Server
      # TODO: voir si on peut pas faire fonctionne all_squash en modifiant la config de idmapd:
      # https://search.nixos.org/options?channel=unstable&show=services.nfs.idmapd.settings&query=idmapd
      services.nfs.server = lib.mkIf isServer {
        enable = true;
        exports = ''
          ${srv-dirs.nfs}    ${zone.networkIp}/${toString zone.prefixLength}(rw,fsid=0,no_subtree_check)
          ${srv-dirs.homes}  ${zone.networkIp}/${toString zone.prefixLength}(rw,sync,no_subtree_check,no_root_squash)
          ${srv-dirs.common} ${zone.networkIp}/${toString zone.prefixLength}(rw,nohide,insecure,sync,no_subtree_check,all_squash,anonuid=65534,anongid=100)
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
        device = "${cfg.serverDomain}.${host.zoneDomain}:/homes";
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
        device = "${cfg.serverDomain}.${host.zoneDomain}:/common";
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
    })
  ];
}
