# SuperTuxKart shared tracks, served over NFS.
#
# :::note
# Declare `services: stk:` on one host of the zone (`config.yaml`): it exports
# `srv-dirs.stkTracks` read-only. Any host wanting the tracks sets
# `darkone.graphic.supertuxkart.enableNfsClient`, which wires `enableClient`
# below; clients address the server by its own hostname, always resolvable.
# :::
#
# :::tip[The server needs no mount]
# `enableClient` on the serving host is a no-op: the tracks are already local,
# and `home/modules/games.nix` links the addons directory straight to them.
# :::
#
# :::caution[Exported to the whole zone prefix]
# Read-only, `all_squash` game data — the same scope as the game's own firewall
# rules, and one less per-client IP list to keep in step with `config.yaml`.
# :::

{
  lib,
  dnfConfig,
  dnfLib,
  host,
  hosts,
  config,
  zone,
  network,
  ...
}:
let
  cfg = config.darkone.service.stk;
  stk = dnfLib.resolveZoneService {
    name = "stk";
    inherit host hosts zone;
    inherit (network) services;
  };
  inherit (config.darkone.system) srv-dirs;

  # The global zone carries no prefix: nothing to anchor an export on, and an
  # empty client spec in `exports(5)` means "everyone".
  inLocalZone = dnfLib.inLocalZone zone;
  zoneCidr = lib.optionalString inLocalZone "${zone.networkIp}/${toString zone.prefixLength}";
  isServing = cfg.enable && inLocalZone;

  # `service/nfs.nix` exports the same NFSv4 root on a host serving both; a
  # second identical line only earns an `exportfs` duplicate warning.
  exportsRoot = !config.darkone.service.nfs.enable;

  # A client whose server is itself has nothing to mount.
  isRemoteClient = cfg.enableClient && cfg.serverName != null && cfg.serverName != host.hostname;
in
assert
  stk.count <= 1 || builtins.throw "Only one 'stk' server can be used, found ${toString stk.count}";
{
  options = {
    darkone.service.stk.enable = lib.mkOption {
      type = lib.types.bool;
      default = stk.isServer;
      description = "Export the shared SuperTuxKart tracks (avoid enable manually)";
    };
    darkone.service.stk.enableClient = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Mount the shared SuperTuxKart tracks of the zone";
    };
    darkone.service.stk.serverName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = stk.server;
      description = "Hostname serving the tracks, default is the zone's `stk` service host";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.stk = {
        displayOnHomepage = false;
        persist.dirs = lib.optional cfg.enable srv-dirs.stkTracks;
        proxy.enable = false;
      };

      assertions = [
        {
          assertion = !cfg.enable || inLocalZone;
          message = "darkone.service.stk on ${host.hostname}: LAN share, unusable in the global zone (no prefix to scope its export on).";
        }
        {
          assertion = !cfg.enableClient || cfg.serverName != null;
          message = "darkone.service.stk on ${host.hostname}: enableClient without a server — declare `services: stk:` on a host of zone '${zone.name}' or set serverName.";
        }
      ];
    }

    #------------------------------------------------------------------------
    # SERVER
    #------------------------------------------------------------------------

    (lib.mkIf isServing {
      darkone.system.services = dnfLib.enableBlock "stk";
      darkone.system.srv-dirs.enableStk = true;

      # `fsid=0` marks the NFSv4 pseudo-root, so clients address the share as
      # `:/stk-tracks`. `nohide` is what makes it visible below that root.
      services.nfs.server = {
        enable = true;
        exports =
          lib.optionalString exportsRoot ''
            ${srv-dirs.nfs}        ${zoneCidr}(ro,fsid=0,no_subtree_check)
          ''
          + ''
            ${srv-dirs.stkTracks}  ${zoneCidr}(ro,nohide,async,no_subtree_check,all_squash,anonuid=65534,anongid=100)
          '';
      };

      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [ dnfConfig.network.ports.nfs ];
      };

      systemd.services.nfs-server = {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };
    })

    #------------------------------------------------------------------------
    # CLIENT
    #------------------------------------------------------------------------

    (lib.mkIf isRemoteClient {
      fileSystems."/mnt/nfs/stk-tracks" = {
        device = "${cfg.serverName}.${host.zoneDomain}:/stk-tracks";
        fsType = "nfs";
        options = [
          "x-systemd.automount" # Mount on demand
          "x-systemd.idle-timeout=600" # Unmount after 10min with no activity
          "noauto" # Useful with automount
          "noatime"
          "ro"
        ];
      };
    })
  ];
}
