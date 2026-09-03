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
#
# :::caution[Exports are per client IP]
# Only the declared `nfs-client` hosts of the zone appear in `/etc/exports`; a
# machine absent from `config.yaml` gets no mount. Root is squashed on every
# share: a client root is `nobody` on the server.
# :::

{
  lib,
  dnfLib,
  dnfConfig,
  host,
  hosts,
  pkgs,
  config,
  zone,
  network,
  ...
}:
let

  # TODO: clients whose servers are not in the same zone (host.features.nfs-client -> external zone)
  cfg = config.darkone.service.nfs;
  nfs = dnfLib.resolveNfs {
    inherit host hosts zone;
    inherit (network) services;
  };
  inherit (nfs)
    hasServer
    isServer
    isClient
    clientIps
    ;
  inherit (config.darkone.system) srv-dirs; # Read only

  # `exports(5)` takes a space-separated list of client specs; a path left
  # without any spec is exported to the world, hence the guard below.
  exportTo = opts: lib.concatMapStringsSep " " (ip: "${ip}(${opts})") clientIps;
in
assert
  nfs.count <= 1 || builtins.throw "Only one 'nfs' server can be used, found ${toString nfs.count}";
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
      darkone.system.services = dnfLib.enableBlock "nfs";

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

      # No `no_root_squash` on the homes: that single word turns "read another
      # user's files" into "drop a key in a wheel member's authorized_keys".
      # No `insecure` either — every client is a Linux kernel mount, which binds
      # under 1024.
      #
      # TODO: see if all_squash can work by tweaking idmapd config:
      # https://search.nixos.org/options?channel=unstable&show=services.nfs.idmapd.settings&query=idmapd
      services.nfs.server = lib.mkIf isServer {
        enable = true;
        exports = lib.optionalString (clientIps != [ ]) ''
          ${srv-dirs.nfs}    ${exportTo "rw,fsid=0,no_subtree_check"}
          ${srv-dirs.homes}  ${exportTo "rw,sync,no_subtree_check"}
          ${srv-dirs.common} ${exportTo "rw,nohide,sync,no_subtree_check,all_squash,anonuid=65534,anongid=100"}
        '';
      };

      # Silence is the safe degradation here, but it is worth saying out loud:
      # the share exists and nothing can reach it.
      warnings = lib.optional (isServer && clientIps == [ ]) ''
        darkone.service.nfs: no host declares `features.nfs-client = "${zone.name}"`,
        ${host.hostname} exports nothing.
      '';

      # Open NFS port, only for lan0 on gateway
      networking.firewall = lib.mkIf isServer (
        lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
          allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [ dnfConfig.network.ports.nfs ];
        }
      );

      # NFS tools
      environment.systemPackages = [ pkgs.nfs-utils ];

      # Start after network
      systemd.services.nfs-server = lib.mkIf isServer {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };

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

          # `bg` only backgrounds a server that does not answer: an unresolved
          # name is a hard error (exit 32) that fails the mount unit outright.
          # On a gateway the local resolver binds :53 seconds after
          # network-online.target, so wait for names to resolve. Elsewhere the
          # target is reached immediately: no boot delay added.
          "x-systemd.requires=nss-lookup.target"
          "x-systemd.after=nss-lookup.target"
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
      systemd.services."mnt-nfs-common.automount" = lib.mkIf isClient {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        reloadIfChanged = lib.mkForce false;
        restartIfChanged = true;
      };
      # "mnt-nfs-homes.automount" = {
      #   reloadIfChanged = lib.mkForce false;
      #   restartIfChanged = true;
      # };

      # Start after network
      systemd.services.nfs-client = lib.mkIf isClient {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };
    })
  ];
}
