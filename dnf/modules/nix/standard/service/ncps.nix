# Nix cache proxy with NCPS module.
#
# To check if a host contains the local gateway in substituters:
#
# ```sh
# nix --extra-experimental-features nix-command show-config | grep substituters
# telnet <your-gateway> 8501
# ```

{
  lib,
  config,
  host,
  network,
  ...
}:
let
  cfg = config.darkone.service.ncps;
in
{
  options = {
    darkone.service.ncps.enable = lib.mkEnableOption "Enable nix cache proxy for packages";
    darkone.service.ncps.isClient = lib.mkEnableOption "Only enable client configuration";
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

  config = lib.mkIf cfg.enable {
    services.ncps =
      lib.mkIf (!cfg.isClient) {
        enable = true;
        cache.dataPath = cfg.dataPath;
        cache.maxSize = "100G";
        cache.hostName = "${host.hostname}";
        upstream.caches = [ "https://cache.nixos.org" ];
      }
      // cfg.extraOptions;

    # Add local gw to substituters.
    # Check with nix --extra-experimental-features nix-command show-config | grep substituters
    nix.settings = {
      substituters = [ "http://${network.gateway.hostname}:8501" ];
      trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
    };
  };
}
