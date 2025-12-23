# Dynamically configured homepage dashboard for your local network.
#
# :::note
# For each DNF service enabled, an entry is automatically added to the homepage configuration.
# :::

{
  lib,
  dnfLib,
  config,
  host,
  zone,
  network,
  ...
}:
let
  cfg = config.darkone.service.homepage;
  hpd = config.services.homepage-dashboard;
  defaultParams = {
    title = "Home";
    description = "Local network home page";
  };
  params = dnfLib.extractServiceParams host network "homepage" defaultParams;

  # TODO: internationalisation
  localTitle = "1. Applications Locales";
  globalTitle = "2. Applications Globales";
  remoteTitle = "3. Applications Distantes";

  isGateway =
    lib.hasAttrByPath [ "gateway" "hostname" ] zone && host.hostname == zone.gateway.hostname;
in
{
  options = {
    darkone.service.homepage.enable = lib.mkEnableOption "Enable homepage dashboard + httpd + host";
    darkone.service.homepage.localServices = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Services to add in Local Applications section";
    };
    darkone.service.homepage.globalServices = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Full network common & public-accessible services";
    };
    darkone.service.homepage.remoteServices = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Services to add in Remote Applications section";
    };
    darkone.service.homepage.bookmarks = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Replace default bookmarks (links)";
    };
    darkone.service.homepage.widgets = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Replace default widgets";
    };
  };

  # TODO: widgets automatiques en fonction du service
  # https://gethomepage.dev/widgets
  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.homepage = {
        inherit defaultParams;
        displayOnHomepage = false;
        proxy.servicePort = hpd.listenPort;
        proxy.defaultService = true;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.homepage.enable = true;
      };

      #------------------------------------------------------------------------
      # Homepage Service
      #------------------------------------------------------------------------

      services.homepage-dashboard = {
        enable = true;
        openFirewall = !isGateway;
        listenPort = 8082;
        allowedHosts = params.fqdn;

        # https://gethomepage.dev/latest/configs/settings/
        settings = {
          title = "${host.name}";
          language = zone.lang;
          hideVersion = true;
          theme = "dark";
          headerStyle = "clean";
          target = "_self";
          layout = {
            ${localTitle} = {
              style = "row";
              columns = 3;
            };
            ${globalTitle} = {
              style = "row";
              columns = 3;
            };
            ${remoteTitle} = {
              style = "row";
              columns = 3;
            };
          };
        };

        # https://gethomepage.dev/latest/configs/bookmarks/
        bookmarks =
          if cfg.bookmarks != [ ] then
            cfg.bookmarks
          else
            [
              {
                "Configuration" = [
                  {
                    "Darkone NixOS Framework" = [
                      {
                        abbr = "DNF";
                        href = "https://darkone-linux.github.io/";
                      }
                    ];
                  }
                  {
                    "Github DNF" = [
                      {
                        abbr = "GHD";
                        href = "https://github.com/darkone-linux/darkone-nixos-framework";
                      }
                    ];
                  }
                  {
                    "Darkone Linux Youtube" = [
                      {
                        abbr = "DLY";
                        href = "https://www.youtube.com/channel/UC0-fyv8kNEmOJnIneC1ZlVg";
                      }
                    ];
                  }
                ];
              }
              {
                "Nix" = [
                  {
                    "Nix Reference Manual" = [
                      {
                        abbr = "NB";
                        href = "https://nix.dev/reference/nix-manual.html";
                      }
                    ];
                  }
                  {
                    "Nix Options" = [
                      {
                        abbr = "NO";
                        href = "https://search.nixos.org/options?channel=unstable";
                      }
                    ];
                  }
                  {
                    "Nix Packages" = [
                      {
                        abbr = "NP";
                        href = "https://search.nixos.org/packages?channel=unstable";
                      }
                    ];
                  }
                ];
              }
            ];

        # https://gethomepage.dev/latest/configs/services/
        services = [
          { ${localTitle} = cfg.localServices; }
          { ${globalTitle} = cfg.globalServices; }
          { ${remoteTitle} = cfg.remoteServices; }
        ];

        # https://gethomepage.dev/latest/configs/service-widgets/
        widgets =
          if cfg.widgets != [ ] then
            cfg.widgets
          else
            [
              {
                resources = {
                  cpu = true;
                  memory = true;
                  uptime = true;
                  #cputemp = true;
                  #network = true;
                  #disk = "/";
                  #network = zone.gateway.wan.interface;
                };
              }
              {
                search = {
                  provider = "google";
                  target = "_self";
                };
              }
            ];

        customCSS = "zoom: 200%;";
      };
    })
  ];
}
