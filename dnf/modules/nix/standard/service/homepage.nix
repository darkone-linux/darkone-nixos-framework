# Automatically configured homepage dashboard for your local network (wip).

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
in
{
  options = {
    darkone.service.homepage.enable = lib.mkEnableOption "Enable homepage dashboard + nginx + host";
    darkone.service.homepage.domainName = lib.mkOption {
      type = lib.types.str;
      default = "home";
      description = "Domain name for homepage, registered in nginx & hosts";
    };
    darkone.service.homepage.adminServices = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Services à ajouter dans la section Administration";
    };
  };

  config = lib.mkIf cfg.enable {

    # Create a virtualhost for homepage
    services.nginx = {
      enable = lib.mkForce true;
      virtualHosts.${cfg.domainName} = {
        default = lib.mkDefault true;
        extraConfig = ''
          client_max_body_size 512M;
        '';
        locations."/".proxyPass = "http://localhost:${toString hpd.listenPort}";
      };
    };

    # Add homepage domain to /etc/hosts
    networking.hosts."${host.ip}" = lib.mkIf config.services.dnsmasq.enable [ "${cfg.domainName}" ];

    services.homepage-dashboard = {
      enable = true;
      openFirewall = true;
      listenPort = 8082;

      # https://gethomepage.dev/latest/configs/settings/
      settings = {
        title = "${host.name} Home";
        language = "en";
        hideVersion = true;
      };

      # https://gethomepage.dev/latest/configs/bookmarks/
      bookmarks = [
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
      services = [ { "Administration" = cfg.adminServices; } ];

      # https://gethomepage.dev/latest/configs/service-widgets/
      widgets = [
        {
          resources = {
            cpu = true;
            cputemp = true;
            memory = true;
            #disk = "/";
            network = network.gateway.wan.interface;
          };
        }
        {
          search = {
            provider = "google";
            target = "_blank";
          };
        }
        # {
        #   openmeteo = {
        #     inherit (network) timezone;
        #     cache = 60;
        #     units = "metric";
        #   };
        # }
      ];

      customCSS = "zoom: 200%;";
    };
  };
}
