# Httpd (nginx) server with PHP84.

{
  lib,
  config,
  pkgs,
  host,
  ...
}:
with lib;
let
  cfg = config.darkone.service.httpd;
  enabledServices = filterAttrs (_: v: v.enable) config.darkone.service.httpd.service;
  mkDomainName =
    name: defaultDomain:
    if attrsets.hasAttrByPath [ "services" "${name}" "domain" ] host then
      host.services."${name}".domain
    else
      defaultDomain;
  mkDisplayName =
    name: defaultDisplayName:
    if attrsets.hasAttrByPath [ "services" "${name}" "title" ] host then
      host.services."${name}".title
    else
      defaultDisplayName;
  mkDescription =
    name: defaultDescription:
    if attrsets.hasAttrByPath [ "services" "${name}" "description" ] host then
      host.services."${name}".description
    else
      defaultDescription;
  mkIcon =
    name: defaultIcon:
    "sh-"
    + (
      if attrsets.hasAttrByPath [ "services" "${name}" "icon" ] host then
        host.services."${name}".icon
      else
        defaultIcon
    );
in
{
  options = {
    darkone.service.httpd.enable = mkEnableOption "Enable httpd (nginx)";
    # darkone.service.httpd.enableUserDir = mkEnableOption "Enable user dir configuration";
    darkone.service.httpd.enablePhp = mkEnableOption "Enable PHP 8.4 with useful modules";
    # darkone.service.httpd.enableVarWww = mkEnableOption "Enable http root on /var/www";

    # Service registration options
    darkone.service.httpd.service = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              enable = mkEnableOption "Enable service proxy";
              displayOnHomepage = mkOption {
                type = types.bool;
                default = true;
                description = "Display a link on homepage";
              };
              domainName = mkOption {
                type = types.str;
                default = name;
                description = "Domain name for the service";
              };
              displayName = mkOption {
                type = types.str;
                default = name;
                description = "Display name in homepage";
              };
              description = mkOption {
                type = types.str;
                default = name;
                description = "Service description for homepage";
              };
              icon = mkOption {
                type = types.str;
                default = name;
                description = "Icon name for homepage (https://dashboardicons.com/)";
              };
              nginx = {
                manageVirtualHost = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Whether to create nginx virtualHost configuration (false for services that manage their own)";
                };
                defaultVirtualHost = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Default nginx virtualhost";
                };
                proxyPort = mkOption {
                  type = types.nullOr types.port;
                  default = null;
                  description = "Service internal port";
                };
                extraConfig = mkOption {
                  type = types.lines;
                  default = ''
                    client_max_body_size 512M;
                  '';
                  description = "Extra nginx virtualHost configuration";
                };
                locations = mkOption {
                  type = types.attrsOf (
                    types.submodule {
                      options = {
                        proxyPass = mkOption {
                          type = types.str;
                          description = "Proxy pass URL";
                        };
                        proxyWebsockets = mkOption {
                          type = types.bool;
                          default = false;
                          description = "Enable WebSocket support";
                        };
                        extraConfig = mkOption {
                          type = types.lines;
                          default = "";
                          description = "Extra location configuration";
                        };
                      };
                    }
                  );
                  default = { };
                  description = "Additional nginx locations";
                };
              };
            };
          }
        )
      );
      default = { };
      description = "Global services configuration";
    };
  };

  # TODO: TLS
  config = lib.mkIf cfg.enable {

    environment.systemPackages = lib.mkIf cfg.enablePhp [
      pkgs.php84
      pkgs.php84Extensions.iconv
      pkgs.php84Extensions.intl
      pkgs.php84Extensions.ldap
      pkgs.php84Extensions.mbstring
      pkgs.php84Extensions.pdo
      pkgs.php84Extensions.pdo_sqlite
      pkgs.php84Extensions.redis
      pkgs.php84Extensions.simplexml
      pkgs.php84Extensions.sqlite3
      pkgs.php84Extensions.xdebug
      pkgs.php84Packages.composer
      pkgs.phpunit
    ];

    services.phpfpm.pools.mypool = lib.mkIf cfg.enablePhp {
      user = "nobody";
      settings = {
        "pm" = "dynamic";
        "listen.owner" = config.services.nginx.user;
        "pm.max_children" = 5;
        "pm.start_servers" = 2;
        "pm.min_spare_servers" = 1;
        "pm.max_spare_servers" = 3;
        "pm.max_requests" = 500;
      };
    };

    services.nginx = {
      enable = mkForce true;

      # virtualHosts.${host.hostname} = lib.mkIf cfg.enableVarWww {
      #   root = "/var/www";
      #   extraConfig = lib.mkIf cfg.enableUserDir ''
      #     location ~ ^/~(.+?)(/.*)?$ {
      #       alias /home/$1/public_html$2;
      #       index index.html index.htm index.php;
      #       autoindex on;
      #     }
      #   '';
      #   locations."~ \\.php$" = lib.mkIf cfg.enablePhp {
      #     extraConfig = ''
      #       fastcgi_pass unix:${config.services.phpfpm.pools.mypool.socket};
      #       fastcgi_index index.php;
      #     '';
      #   };
      # };

      # Configure virtual hosts
      virtualHosts = mkMerge (
        mapAttrsToList (
          name: srv:
          mkIf srv.nginx.manageVirtualHost {
            ${(mkDomainName name srv.domainName)} = {
              default = srv.nginx.defaultVirtualHost;
              inherit (srv.nginx) extraConfig;
              locations = mkMerge [

                # Default proxy location if proxyPort is set
                (mkIf (srv.nginx.proxyPort != null) {
                  "/" = {
                    proxyPass = "http://localhost:${toString srv.nginx.proxyPort}";
                  };
                })

                # Additional custom locations
                (mapAttrs (_: loc: {
                  inherit (loc) proxyPass;
                  inherit (loc) proxyWebsockets;
                  inherit (loc) extraConfig;
                }) srv.nginx.locations)
              ];
            };
          }
        ) enabledServices
      );
    };

    # Add domains to /etc/hosts
    networking.hosts = mkMerge (
      mapAttrsToList (
        name: srv:
        mkIf config.services.dnsmasq.enable { "${host.ip}" = [ (mkDomainName name srv.domainName) ]; }
      ) enabledServices
    );

    # Add services to homepage
    darkone.service.homepage.appServices = mapAttrsToList (name: srv: {
      ${(mkDisplayName name srv.displayName)} = mkIf srv.displayOnHomepage {
        description = mkDescription name srv.description;
        href = "http://${(mkDomainName name srv.domainName)}";
        icon = mkIcon name srv.icon;
      };
    }) enabledServices;

    # TODO: fix userdir access
    #users.users.nginx.extraGroups = lib.mkIf cfg.enableUserDir [ "users" ];

    networking.firewall.allowedTCPPorts = [ 80 ];
  };
}
