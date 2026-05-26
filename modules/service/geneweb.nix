# GeneWeb — wrapper DNF du module nixpkgs (en provenance de la PR #522751).
#
# :::tip
# Le module upstream `services.geneweb.*` est importé en amont par
# `lib/mk-configuration.nix` (tant que la PR n'est pas mergée). Le paquetage
# `pkgs.geneweb` provient de l'overlay `lib/overlays/geneweb.nix`.
# :::
#
# Aim: configurer, utiliser, maintenir.

{
  lib,
  dnfLib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.geneweb;
  gwCfg = config.services.geneweb;
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

        # `baseDir` héberge les bases généalogiques : données primaires +
        # contenu base-like → catégoriser comme dbDirs pour aligner sur
        # la stratégie de persistance/backup du framework.
        persist.dbDirs = [ gwCfg.baseDir ];

        # `services.geneweb.port` est l'option upstream qui pilote
        # l'écoute HTTP locale ; le reverse proxy DNF s'y branche.
        proxy.servicePort = gwCfg.port;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "geneweb";

      #------------------------------------------------------------------------
      # GeneWeb Service
      #------------------------------------------------------------------------

      services.geneweb = {
        enable = true;
        package = pkgs.geneweb;

        # `openFirewall = false` : sur un host gateway, le reverse proxy
        # DNF expose le service ; sur les autres hosts, l'accès LAN est
        # géré par `dnfLib.mkInternalFirewall` côté framework. Garder le
        # port `2317` upstream par défaut tant que le consumer n'override pas.
        openFirewall = false;
      };
    })
  ];
}
