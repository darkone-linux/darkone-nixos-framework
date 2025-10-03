# Dynamically configured homepage dashboard for your local network.
#
# :::note
# For each DNF service enabled, an entry is automatically added to the homepage configuration.
# :::

{
  lib,
  config,
  host,
  network,
  ...
}:
let
  inherit network;
  inherit host;
  cfg = config.darkone.service.homepage;
  hpd = config.services.homepage-dashboard;
  language = lib.toLower (builtins.substring 0 2 network.locale);
in
{
  options = {
    darkone.service.homepage.enable = lib.mkEnableOption "Enable homepage dashboard + nginx + host";
    darkone.service.homepage.domainName = lib.mkOption {
      type = lib.types.str;
      default = host.hostname;
      description = "Domain name for homepage (default is hostname)";
    };
    darkone.service.homepage.adminServices = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Services to add in Administration section";
    };
    darkone.service.homepage.appServices = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Services to add in Applications section";
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
  config = lib.mkIf cfg.enable {

    # httpd + dnsmasq + homepage registration
    darkone.service.httpd = {
      enable = true;
      service.homepage = {
        enable = true;
        displayOnHomepage = false;
        domainName = host.hostname;
        displayName = "Homepage";
        description = "Page d'accueil du réseau local";
        nginx = {
          proxyPort = hpd.listenPort;
          defaultVirtualHost = true;
        };
      };
    };

    services.homepage-dashboard = {
      enable = true;
      openFirewall = true;
      listenPort = 8082;

      # https://gethomepage.dev/latest/configs/settings/
      settings = {
        title = "${host.name}";
        inherit language;
        hideVersion = true;
        theme = "dark";
        headerStyle = "clean";
        layout = {
          Applications = {
            style = "row";
            columns = 3;
          };
          Administration = {
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
                      href = "https://search.nixos.org/options";
                    }
                  ];
                }
                {
                  "Nix Packages" = [
                    {
                      abbr = "NP";
                      href = "https://search.nixos.org/packages";
                    }
                  ];
                }
              ];
            }
          ];

      # https://gethomepage.dev/latest/configs/services/
      services = [
        { "Applications" = cfg.appServices; }
        { "Administration" = cfg.adminServices; }
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
                #network = network.gateway.wan.interface;
              };
            }
            {
              search = {
                provider = "google";
                target = "_blank";
              };
            }
          ];

      customCSS = "zoom: 200%;";
    };
  };
}
