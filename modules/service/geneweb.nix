# GeneWeb — wrapper DNF du module nixpkgs (en provenance de la PR #522751).
#
# :::tip
# Le module upstream `services.geneweb.*` est importé en amont par
# `lib/mk-configuration.nix` (tant que la PR n'est pas mergée). Le paquetage
# `pkgs.geneweb` provient de l'overlay `lib/overlays/geneweb.nix`.
# :::
#
# :::caution[Required sops secrets]
# When enabled, this module reads friend and wizard passwords from the sops
# secrets `geneweb-friend` and `geneweb-wizard`. Add the entries to
# `usr/secrets/` before rebuilding, otherwise sops-nix activation will fail.
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

        friendPasswordFile = config.sops.secrets."geneweb-friend".path;
        wizardPasswordFile = config.sops.secrets."geneweb-wizard".path;

        # `openFirewall = false` : sur un host gateway, le reverse proxy
        # DNF expose le service ; sur les autres hosts, l'accès LAN est
        # géré par `dnfLib.mkInternalFirewall` côté framework. Garder le
        # port `2317` upstream par défaut tant que le consumer n'override pas.
        openFirewall = false;
      };
    })
  ];
}
