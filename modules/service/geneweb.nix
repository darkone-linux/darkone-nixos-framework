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
# :::caution[SOPS secrets]
# The option `enablePasswords` reads friend and wizard passwords from the sops
# secrets `geneweb-friend` and `geneweb-wizard`. If enabled, add the entries to
# `usr/secrets/` before rebuilding, otherwise sops-nix activation will fail.
#
# **Important note:** Sops passwords must be sent in plain text to the Geneweb
# daemon. For greater security, it is better to define these passwords in the
# database configuration file (your-base.gwf) rather than using `enablePasswords`.
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
    darkone.service.geneweb.enablePasswords = lib.mkEnableOption "Enable sops passwords (not recommanded)";
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

      networking.firewall = dnfLib.mkInternalFirewall host zone [ gwCfg.port ];

      #------------------------------------------------------------------------
      # Sops secrets
      #------------------------------------------------------------------------

      # Friend password, provisioned from sops.
      sops.secrets."geneweb-friend" = lib.mkIf cfg.enablePasswords {
        mode = "0400";
        owner = "geneweb";
      };

      # Wizard password, provisioned from sops.
      sops.secrets."geneweb-wizard" = lib.mkIf cfg.enablePasswords {
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
        friendPasswordFile = lib.mkIf cfg.enablePasswords config.sops.secrets."geneweb-friend".path;
        wizardPasswordFile = lib.mkIf cfg.enablePasswords config.sops.secrets."geneweb-wizard".path;
        openFirewall = false;
      };
    })
  ];
}
