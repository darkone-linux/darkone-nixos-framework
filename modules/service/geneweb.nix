# GeneWeb — Powerful Genealogy Service.
#
# :::note[Service currently being validated]
# DNF wrapper around the nixpkgs module (from [PR #522751](https://github.com/NixOS/nixpkgs/pull/522751)).
# :::
#
# :::tip[Database declaration]
# To declare a `base.gw` file (default dir is `/var/lib/geneweb`), 
# add this in your server configuration:
# ```nix
# services.geneweb.databases.base = {};
# ```
# :::
#
# :::caution[Required sops secrets]
# When enabled, this module reads friend and wizard passwords from the sops
# secrets `geneweb-friend` and `geneweb-wizard`. Add the entries to
# `usr/secrets/` before rebuilding, otherwise sops-nix activation will fail.
# :::

{
  lib,
  dnfLib,
  config,
  pkgs,
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.service.geneweb;
  gwCfg = config.services.geneweb;
  defaultParams = {
    title = "Geneweb";
    icon = "hypermind";
  };
in
{
  options = {
    darkone.service.geneweb.enable = lib.mkEnableOption "Enable local GeneWeb genealogy service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.geneweb = {
        inherit defaultParams;
        persist.dbDirs = [ gwCfg.baseDir ];
        proxy.servicePort = gwCfg.port;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "geneweb";

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = dnfLib.mkInternalFirewall host zone [
        gwCfg.port
      ];

      #------------------------------------------------------------------------
      # Sops secrets
      #------------------------------------------------------------------------

      # Friend password, provisioned from sops.
      sops.secrets."geneweb-friend" = {
        mode = "0400";
        owner = "geneweb";
      };

      # Wizard password, provisioned from sops.
      sops.secrets."geneweb-wizard" = {
        mode = "0400";
        owner = "geneweb";
      };

      #------------------------------------------------------------------------
      # GeneWeb Service
      #------------------------------------------------------------------------

      services.geneweb = {
        enable = true;
        package = pkgs.geneweb;
        defaultLang = zone.lang;

        friendPasswordFile = config.sops.secrets."geneweb-friend".path;
        wizardPasswordFile = config.sops.secrets."geneweb-wizard".path;
        
        openFirewall = false;
      };
    })
  ];
}
