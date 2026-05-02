# Local Artifical Intelligence (open-webui + ollama + llms).

{
  lib,
  dnfLib,
  config,
  pkgs,
  host,
  zone,
  network,
  ...
}:
let
  cfg = config.darkone.service.ai;
  internalPort = 9758;
  defaultParams = {
    title = "Local AI";
    description = "Local Generative AI";
    icon = "conduit-open-webui";
  };
  params = dnfLib.extractServiceParams host network "ai" defaultParams;
in
{
  options = {
    darkone.service.ai.enable = lib.mkEnableOption "Enable local AI service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.ai = {
        inherit defaultParams;
        persist = {
          dirs = [ config.services.open-webui.stateDir ];
        };
        proxy.servicePort = internalPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.ai.enable = true;
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [
          internalPort
          config.services.ollama.port
        ];
      };

      #------------------------------------------------------------------------
      # AI Tools & dependencies
      #------------------------------------------------------------------------

      environment.systemPackages = with pkgs; [
        gollama # Ollama models manager
        ffmpeg # Open WebUI
      ];

      #------------------------------------------------------------------------
      # Ollama service
      #------------------------------------------------------------------------

      services.ollama = {
        enable = true;
        openFirewall = false;
        host = "0.0.0.0";
        loadModels = [
          "deepseek-r1:latest" # 8b
          "gemma4:e4b"
          "llama3.2:3b"
          "mistral-small3.2:latest" # 24b
          "translategemma:27b"
        ];
      };

      #------------------------------------------------------------------------
      # Open WebUI Service
      #------------------------------------------------------------------------

      # Sops secret
      sops.secrets.oidc-secret-open-webui = { };
      sops.secrets.default-password = { };
      sops.templates.open-webui-env-file = {
        content = ''
          OAUTH_CLIENT_SECRET=${config.sops.placeholder.oidc-secret-open-webui}
          WEBUI_ADMIN_PASSWORD=${config.sops.placeholder.default-password}
        '';
        mode = "0400";
        owner = "open-webui"; # (non) dynamic user name
      };

      # We need the open-webui user for sops...
      users.users.open-webui = {
        isSystemUser = true;
        group = "open-webui";
      };
      users.groups.open-webui = { };

      # On limite le nombre de file descriptors car ce service est très gourmand
      systemd.services.open-webui.serviceConfig = {
        LimitNOFILE = 65536;
      };

      # Main Open WebUI service configuration
      services.open-webui = {
        enable = true;
        port = internalPort;
        host = params.ip;

        # https://docs.openwebui.com/reference/env-configuration
        environment = {
          WEBUI_URL = params.href;
          ENABLE_SIGNUP = "False";
          WEBUI_ADMIN_EMAIL = "admin@${network.domain}";
          WEBUI_ADMIN_NAME = "Open WebUI Admin";
          DEFAULT_LOCALE = zone.lang;
          DEFAULT_MODELS = "llama3.2:3b";
          ANONYMIZED_TELEMETRY = "False";
          DO_NOT_TRACK = "True";
          SCARF_NO_ANALYTICS = "True";
          OLLAMA_API_BASE_URL = "http://${params.ip}:${toString config.services.ollama.port}";
          WEBUI_AUTH = "True";

          # Required for OIDC
          OAUTH_CLIENT_ID = "open-webui";
          OPENID_PROVIDER_URL = "https://idm.${network.domain}/oauth2/openid/open-webui/.well-known/openid-configuration";
          OAUTH_CODE_CHALLENGE_METHOD = "S256"; # PKCE -> https://docs.openwebui.com/reference/env-configuration#oauth_code_challenge_method

          # Auto-signup
          ENABLE_OAUTH_SIGNUP = "True";
          DEFAULT_USER_ROLE = "user"; # Not pending
          WEBUI_SESSION_COOKIE_SAME_SITE = "lax"; # https://docs.openwebui.com/reference/env-configuration#webui_session_cookie_same_site

          # A activer pour le paramétrage... TODO: automatique, déclaratif
          # Paramétrer ce que voient les utilisateurs par défaut dans groups -> autorisations : modèles, etc.
          # Puis pour chaque modèle, rendre "public" ceux pour lesquels les users ont accès
          ENABLE_LOGIN_FORM = "True";
          ENABLE_PASSWORD_AUTH = "True";

          # Autorisations
          USER_PERMISSIONS_WORKSPACE_MODELS_ACCESS = "True";

          # Optional but recommended
          OAUTH_PROVIDER_NAME = "IDM";
          OAUTH_SCOPES = "openid email profile groups";
          OPENID_REDIRECT_URI = "${params.href}/oauth/oidc/callback";
          OAUTH_MERGE_ACCOUNTS_BY_EMAIL = "True";
        };

        # OIDC Secret
        environmentFile = config.sops.templates.open-webui-env-file.path;
      };
    })
  ];
}
