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
  # Next-gen auth on the matrix server of THIS host (cf. mobile guide below).
  hasMas = config.darkone.service.matrix.mas.enable;

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
      # No `oidc_static_clients` / `oidc_metadata` override: both assumed
      # Kanidm was the OIDC issuer, which it never is for a matrix client.
      # With MAS the issuer is `matrix.<domain>`, and forcing `client_uri` to
      # the IDM host made MAS reject Element's dynamic registration ("invalid
      # redirect_uri": a native app's custom scheme must reverse-DNS-match its
      # client_uri, `io.element.desktop` vs `idm.<domain>`). Element then fell
      # back to the legacy browser SSO flow. Its own defaults register fine.
      jitsi.preferred_domain = if hasJitsi then jitsiDomain else "meet.jit.si";

      # Which app the phone landing page offers. Element X only talks to a
      # MAS-backed homeserver, so follow that. Upstream spells Element X
      # "element" (its default) and the legacy app "element-classic", which
      # works in both modes and stays the safe fallback: a matrix server on
      # another host reads `mas.enable` as its default here.
      mobile_guide_toast = true; # default
      mobile_guide_app_variant = if hasMas then "element" else "element-classic";
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
