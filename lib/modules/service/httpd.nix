{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.httpd;
in
{
  options = {
    darkone.service.httpd.enable = lib.mkEnableOption "Enable httpd (apache)";
  };

  #environment.systemPackages =
  #let
  #  php = pkgs.php.buildEnv { extraConfig = "display_errors = on"; };
  #in [
  #  php
  #];

  config = lib.mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      php84
      php84Extensions.iconv
      php84Extensions.intl
      php84Extensions.ldap
      php84Extensions.mbstring
      php84Extensions.pdo
      php84Extensions.pdo_sqlite
      php84Extensions.redis
      php84Extensions.simplexml
      php84Extensions.sqlite3
      php84Extensions.xdebug
      php84Packages.composer
      phpunit
    ];

    # Apache
    services.httpd = {
      enable = true;
      enablePHP = true;
      phpPackage = pkgs.php84;
      extraModules = [ "userdir" ];

      # TODO: email from configuration
      adminAddr = "admin@localhost";
      virtualHosts.localhost = {
        documentRoot = "/var/www";

        # Works only with /home/xxx, not with /mnt/home/xxx
        #enableUserDir = true;
        extraConfig = ''
          UserDir /mnt/home/*/www
          UserDir disabled root
          <Directory "/mnt/home/*/www">
              AllowOverride FileInfo AuthConfig Limit Indexes
              Options MultiViews Indexes SymLinksIfOwnerMatch IncludesNoExec
              <Limit GET POST OPTIONS>
                  Require all granted
              </Limit>
              <LimitExcept GET POST OPTIONS>
                  Require all denied
              </LimitExcept>
          </Directory>

          <Directory "/var/www">
            DirectoryIndex index.php index.htm index.html
              Allow from *
              Options FollowSymLinks
              AllowOverride All
          </Directory>
        '';
      };
    };
  };
}
