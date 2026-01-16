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
  idmUri = "https://idm.${network.domain}";

  defaultParams = {
    description = "Messaging & VoIP client";
  };

  elementWeb = pkgs.element-web.override {
    conf = {
      default_server_config."m.homeserver".base_url = localMatrixServer;
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
      oidc_static_clients."${idmUri}/".client_id = "matrix-synapse";
      oidc_metadata = {
        client_uri = idmUri;
        logo_uri = idmUri + "/pkg/img/logo.svg";
      };

      # "Element X" n'est pas fonctionnel pour OIDC -> Element Classic pour l'instant
      mobile_guide_toast = true; # default
      mobile_guide_app_variant = "element-classic";
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
            root * /etc/element-web
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

      # Get and expose element web sources
      environment.etc."element-web".source = elementWeb;
    })
  ];
}
