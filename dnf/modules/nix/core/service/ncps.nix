# Nix cache proxy with NCPS module.

{
  lib,
  config,
  host,
  ...
}:
let
  cfg = config.darkone.service.ncps;
in
{
  options = {
    darkone.service.ncps.enable = lib.mkEnableOption "Enable nix cache proxy for packages";
    darkone.service.ncps.dataPath = lib.mkOption {
      type = lib.types.path;
      default = /var/cache/ncps;
      description = "Nix cache proxy cache folder";
    };
    darkone.service.ncps.extraOptions = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "services.ncps extra options";
    };
  };

  config = lib.mkIf cfg.enable {
    services.ncps = {
      enable = true;
      cache.dataPath = cfg.dataPath;
      cache.maxSize = "100G";
      cache.hostName = "${host.hostname}";
      upstream.caches = [ "https://cache.nixos.org" ];
    } // cfg.extraOptions;
  };
}
