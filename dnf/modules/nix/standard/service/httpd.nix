# Httpd (nginx) server with PHP84.

{
  lib,
  config,
  pkgs,
  host,
  ...
}:
let
  cfg = config.darkone.service.httpd;
in
{
  options = {
    darkone.service.httpd.enable = lib.mkEnableOption "Enable httpd (nginx)";
    darkone.service.httpd.enableUserDir = lib.mkEnableOption "Enable user dir configuration";
    darkone.service.httpd.enablePhp = lib.mkEnableOption "Enable PHP 8.4 with useful modules";
    darkone.service.httpd.enableVarWww = lib.mkEnableOption "Enable http root on /var/www";
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
      enable = true;
      virtualHosts.${host.hostname} = lib.mkIf cfg.enableVarWww {
        root = "/var/www";
        extraConfig = lib.mkIf cfg.enableUserDir ''
          location ~ ^/~(.+?)(/.*)?$ {
            alias /home/$1/public_html$2;
            index index.html index.htm index.php;
            autoindex on;
          }
        '';
        locations."~ \\.php$" = lib.mkIf cfg.enablePhp {
          extraConfig = ''
            fastcgi_pass unix:${config.services.phpfpm.pools.mypool.socket};
            fastcgi_index index.php;
          '';
        };
      };
    };

    # TODO: fix userdir access
    #users.users.nginx.extraGroups = lib.mkIf cfg.enableUserDir [ "users" ];

    networking.firewall.allowedTCPPorts = [ 80 ];
  };
}
