# Element web client for local matrix service.

{
  lib,
  config,
  network,
  zone,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.element;
  country = builtins.substring 3 2 zone.locale;
  localMatrixServer = "https://matrix.${network.domain}";

  defaultParams = {
    description = "Messaging & VoIP client";
  };
  #params = dnfLib.extractServiceParams host network "element" defaultParams;

  clientConfig."m.homeserver".base_url = localMatrixServer;
  elementWeb = pkgs.element-web.override {
    conf = {
      default_server_config = clientConfig;
      show_labs_settings = true;
      default_theme = "dark";
      default_federate = false;
      default_country_code = country;
      room_directory.servers = [ localMatrixServer ];
      brand = network.domain;
      sso_redirect_options = {
        immediate = true;
        on_welcome_page = true;
        on_login_page = true;
      };
    };
  };
in
{
  options = {
    darkone.service.element.enable = lib.mkEnableOption "Enable local element service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.element = {
        inherit defaultParams;
        proxy = {
          enable = true;
          hasReverseProxy = false;
          extraConfig = ''
            root * ${elementWeb}
            file_server
          '';
        };
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.element.enable = true;
      };

      # Element web dependency (required)
      environment.systemPackages = [ elementWeb ];

    })
  ];
}
