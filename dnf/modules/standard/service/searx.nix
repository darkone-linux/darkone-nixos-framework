# A full-configured searx git forge.

{
  lib,
  dnfLib,
  config,
  network,
  zone,
  host,
  ...
}:
let
  cfg = config.darkone.service.searx;
  defaultParams = {
    icon = "searxng";
  };
  params = dnfLib.extractServiceParams host network "searx" defaultParams;
  srvPort = 8283;
in
{
  options = {
    darkone.service.searx.enable = lib.mkEnableOption "Enable local search proxy";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.searx = {
        inherit defaultParams;
        displayOnHomepage = false; # Accessible via the homepage search bar
        persist.dirs = [ "/var/lib/searx" ];
        proxy.servicePort = srvPort;
        proxy.isInternal = true;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.searx.enable = true;
      };

      #------------------------------------------------------------------------
      # Dependencies
      #------------------------------------------------------------------------

      # Sops DB password file
      sops.secrets.searx-secret-key = { };
      sops.templates.searx-env = {
        content = ''
          SEARXNG_SECRET=${config.sops.placeholder.searx-secret-key}
        '';
        mode = "0400";
        owner = "searx";
        restartUnits = [ "searx.service" ];
      };

      #------------------------------------------------------------------------
      # Searx Service
      #------------------------------------------------------------------------

      services.searx = {
        enable = true;

        # https://docs.searxng.org/admin/settings/index.html
        settings = {
          general = {
            debug = false;
            instance_name = params.description;
            donation_url = false;
            contact_url = false;
            privacypolicy_url = false;
            enable_metrics = false;
          };
          server = {
            base_url = params.href;
            port = srvPort;
            bind_address = params.ip;
            image_proxy = true;
            default_theme = "oscar";
            default_locale = zone.lang;
          };
          locales = [ zone.lang ];
          ui = {
            static_use_hash = true;
            default_locale = zone.lang;
            query_in_title = false;
            infinite_scroll = true;
            center_alignment = false;
            default_theme = "simple";
            theme_args.simple_style = "auto";
            search_on_category_select = true;
          };

          # TODO: automatique
          brand = {
            issue_url = "git.${network.domain}";
            docs_url = "notes.${network.domain}";
          };

          search = {
            default_lang = zone.lang;
            autocomplete = "qwant";
            safe_search = 2; # Strict
          };

          engines = lib.mapAttrsToList (name: value: { inherit name; } // value) {

            # Fonctionnels et à peu près performants...
            "wikipedia" = {
              disabled = false;
              weight = 99;
            };
            "startpage" = {
              disabled = false;
              weight = 98;
            };
            "duckduckgo" = {
              disabled = false;
              weight = 97;
            };

            # Blacklistés ou ne répondent pas...
            # "google ${zone.lang}" = {
            #   engine = "google";
            #   language = zone.lang;
            #   weight = 100;
            #   disable = true;
            # };
            "qwant" = {
              disabled = true;
              weight = 100;
            };

            # Désactivation (ou non) pour y gagner en perfs
            "1x".disabled = true;
            "artic".disabled = true;
            "bing images".disabled = false;
            "bing videos".disabled = false;
            "bing".disabled = true;
            "brave".disabled = true;
            "brave.images".disabled = true;
            "brave.news".disabled = true;
            "brave.videos".disabled = true;
            "crowdview".disabled = true;
            "curlie".disabled = true;
            "currency".disabled = true;
            "dailymotion".disabled = true;
            "ddg definitions".disabled = true;
            "deviantart".disabled = true;
            "dictzone".disabled = true;
            "duckduckgo images".disabled = true;
            "duckduckgo videos".disabled = true;
            "flickr".disabled = false;
            "google images".disabled = true;
            "google news".disabled = false;
            "google play movies".disabled = true;
            "google videos".disabled = false;
            "google".disabled = true;
            "imgur".disabled = true;
            "invidious".disabled = true;
            "library of congress".disabled = true;
            "lingva".disabled = true;
            "material icons".disabled = true;
            "mojeek".disabled = true;
            "mwmbl".disabled = true;
            "odysee".disabled = true;
            "openverse".disabled = true;
            "peertube".disabled = true;
            "pinterest".disabled = true;
            "piped".disabled = true;
            "qwant images".disabled = true;
            "qwant videos".disabled = true;
            "rumble".disabled = true;
            "sepiasearch".disabled = true;
            "svgrepo".disabled = true;
            "unsplash".disabled = true;
            "vimeo".disabled = false;
            "wallhaven".disabled = true;
            "wikibooks".disabled = true;
            "wikicommons.images".disabled = true;
            "wikidata".disabled = true;
            "wikiquote".disabled = true;
            "wikisource".disabled = true;
            "wikispecies".disabled = true;
            "wikiversity".disabled = true;
            "wikivoyage".disabled = true;
            "yacy images".disabled = true;
            "youtube".disabled = false;
          };
        };
        environmentFile = config.sops.templates.searx-env.path;
      };
    })
  ];
}
