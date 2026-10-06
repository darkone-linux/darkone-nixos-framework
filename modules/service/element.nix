# Element web client for local matrix service.

{
  lib,
  dnfLib,
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

  jitsiService = lib.findFirst (s: s.name == "jitsi-meet" && s.zone == "www") null network.services;
  hasJitsi = jitsiService != null;
  jitsiDomain = lib.optionalString hasJitsi (
    if lib.hasAttr "domain" jitsiService then jitsiService.domain else jitsiService.name
  );

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

      # No `oidc_static_clients`/`oidc_metadata` override: MAS (`matrix.<domain>`)
      # is the issuer, and a `client_uri` on the IDM host made it reject
      # Element's dynamic registration. Its own defaults register fine.
      jitsi.preferred_domain = if hasJitsi then jitsiDomain else "meet.jit.si";

      # Element X only talks to a MAS-backed homeserver, which every DNF
      # matrix server now is. Upstream spells it "element" (its default).
      mobile_guide_toast = true; # default
      mobile_guide_app_variant = "element";
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
      darkone.system.services = dnfLib.enableBlock "element";

      # Get and expose element web sources
      environment.etc."element-web".source = elementWeb;
    })
  ];
}
