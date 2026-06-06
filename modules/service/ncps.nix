# Nix cache proxy with NCPS module.
#
# This module is activated by core. Server and clients are automatically detected.
#
# :::tip
# To check if a host contains the local gateway in substituters:
#
# ```sh
# nix --extra-experimental-features nix-command show-config | grep substituters
# telnet <your-gateway> 8501
# ```
# :::

{
  lib,
  config,
  network,
  pkgs,
  host,
  hosts,
  zone,
  dnfLib,
  dnfConfig,
  workDir,
  ...
}:
let
  inherit (dnfLib) findHost preferredIp;
  cfg = config.darkone.service.ncps;
  hostIsLocal = host.zone != "www";
  ncpsService = lib.findFirst (s: s.zone == zone.name && s.name == "ncps") null network.services;

  # A zone may declare no ncps service (eg. minimal hosts); stay null-safe so
  # `serverName` does not select `.host` on a missing service.
  serverName = if ncpsService == null then null else ncpsService.host;
  hasServer = hostIsLocal && serverName != null;
  isServer = hostIsLocal && host.hostname == serverName;
  isClient = hostIsLocal && hasServer;
  ncpsPort = dnfConfig.network.ports.ncps;
  harmoniaPort = dnfConfig.network.ports.harmonia;

  # Harmonia upstreams in scope for this zone's ncps: same-zone instances
  # (highest priority, reached over the LAN) first, then any global harmonia
  # (reached cross-zone over the tailnet). Other zones' non-global harmonia are
  # never used.
  harmoniaInZone = lib.filter (s: s.name == "harmonia" && s.zone == zone.name) network.services;
  harmoniaGlobal = lib.filter (
    s: s.name == "harmonia" && (s.global or false) && s.zone != zone.name
  ) network.services;
  harmoniaUrls =
    (map (s: "http://${(findHost s.host s.zone hosts).ip}:${toString harmoniaPort}") harmoniaInZone)
    ++ (map (
      s: "http://${preferredIp (findHost s.host s.zone hosts)}:${toString harmoniaPort}"
    ) harmoniaGlobal);

  # Deployment-wide harmonia public key (committed like nix.pub). Present only
  # once the admin has provisioned the binary-cache key; absent in standalone
  # test mode where the consumer workspace does not exist.
  harmoniaPubFile = workDir + "/usr/secrets/harmonia.pub";
  harmoniaKeys = lib.optional (
    (!config.darkone.test.standalone) && builtins.pathExists harmoniaPubFile
  ) (lib.fileContents harmoniaPubFile);
in
{
  options = {
    darkone.service.ncps.enable = lib.mkEnableOption "Enable nix cache proxy for packages";
    darkone.service.ncps.dataPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/ncps";
      description = "Nix cache proxy cache folder";
    };
    darkone.service.ncps.extraOptions = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "services.ncps extra options";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.ncps = {
        displayOnHomepage = false;
        persist = {
          varDirs = [ config.services.ncps.cache.dataPath ];
        };
        proxy.enable = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.ncps.enable = isServer;
      };

      #------------------------------------------------------------------------
      # NCPS Service
      #------------------------------------------------------------------------

      services.ncps = lib.mkIf isServer (
        {
          package = pkgs.ncps;
          enable = true;
          cache = {
            storage.local = cfg.dataPath;
            maxSize = "40G";
            hostName = "${host.hostname}.${zone.domain}";
            lru.schedule = "0 2 * * *";
            allowPutVerb = true;
            allowDeleteVerb = true;
            upstream = {
              urls = harmoniaUrls ++ [
                "https://cache.nixos.org"
                "https://nix-community.cachix.org"
              ];
              publicKeys = harmoniaKeys ++ [
                "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
                "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
              ];
            };
          };
        }
        // cfg.extraOptions
      );

      # Add local gw to substituters.
      # Check with nix --extra-experimental-features nix-command config show | grep substituters
      nix.settings = {
        substituters = [
          (lib.mkIf isClient "http://${zone.gateway.hostname}.${zone.domain}:${toString ncpsPort}")
          "https://nix-community.cachix.org"
        ];
        trusted-public-keys = harmoniaKeys ++ [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
      };
    })
  ];
}
