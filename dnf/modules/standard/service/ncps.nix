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
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.service.ncps;
  hostIsLocal = host.zone != "www";
  serverName =
    (lib.findFirst (s: s.zone == zone.name && s.name == "ncps") null network.services).host;
  hasServer = hostIsLocal && serverName != null;
  isServer = hostIsLocal && host.hostname == serverName;
  isClient = hostIsLocal && hasServer;
  ncpsPort = 8501;
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

      services.ncps =
        lib.mkIf isServer {
          enable = true;
          cache = {
            inherit (cfg) dataPath;
            maxSize = "20G";
            hostName = "${host.hostname}.${zone.domain}";
            lru.schedule = "0 2 * * *";
            allowPutVerb = true;
            allowDeleteVerb = true;
          };
          upstream = {
            caches = [
              "https://cache.nixos.org"
              "https://nix-community.cachix.org"
            ];
            publicKeys = [
              "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
              "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
            ];
          };
        }
        // cfg.extraOptions;

      # Add local gw to substituters.
      # Check with nix --extra-experimental-features nix-command config show | grep substituters
      nix.settings = {
        substituters = [
          (lib.mkIf isClient "http://${zone.gateway.hostname}.${zone.domain}:${toString ncpsPort}")
          "https://nix-community.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
      };
    })
  ];
}
