# Local Artifical Intelligence (open-webui + ollama + llms).

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  pkgs,
  pkgs-stable,
  host,
  hosts,
  zone,
  network,
  ...
}:
let
  cfg = config.darkone.service.ai;
  internalPort = dnfConfig.network.ports.ai;
  defaultParams = {
    title = "Local AI";
    description = "Local Generative AI";
    icon = "conduit-open-webui";
  };
  params = dnfLib.extractServiceParams host network "ai" defaultParams;

  inherit
    (dnfLib.mkOidcContext {
      name = "ai";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;

  # Temporary (`config/workarounds.nix`, `fpdf2-image-test`): fpdf2 2.8.5
  # `test_image_with_explicit_dimensions` fails on a PDF hash mismatch.
  python3Stable = pkgs-stable.python3.override {
    self = python3Stable;
    packageOverrides = _pyfinal: pyprev: {
      fpdf2 = pyprev.fpdf2.overridePythonAttrs (old: {
        disabledTests = (old.disabledTests or [ ]) ++ [ "test_image_with_explicit_dimensions" ];
      });
    };
  };
  openWebuiStable = pkgs-stable.open-webui.override { python3Packages = python3Stable.pkgs; };
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

      # Kanidm OAuth2 client template
      darkone.service.idm.oauth2.ai = {
        displayName = "Open WebUI";
        imageFile = ./../../assets/app-icons/open-webui.svg;
        redirectPaths = [ "/oauth/oidc/callback" ];
        landingPath = "/";
        preferShortUsername = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "ai";

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = dnfLib.mkInternalFirewall host zone [
        internalPort
        config.services.ollama.port
      ];

      #------------------------------------------------------------------------
      # AI Tools & dependencies
      #------------------------------------------------------------------------

      environment.systemPackages = with pkgs; [
        gollama # Ollama models manager
        ffmpeg-full # Open WebUI; same variant as immich, avoids buildEnv collisions
      ];

      #------------------------------------------------------------------------
      # Ollama service
      #------------------------------------------------------------------------

      services.ollama = {
        enable = true;
        openFirewall = lib.mkDefault false;
        host = "0.0.0.0";
        loadModels = [
          "llama3.2:3b"
          "gemma4:e4b"
          "gemma4:12b"
          "deepseek-r1:latest" # 8b
        ];
      };

      #------------------------------------------------------------------------
      # Open WebUI Service
      #------------------------------------------------------------------------

      # Sops secrets. The admin account gets its own generated password, read
      # back with `just sops` — open-webui hashes it at first start.
      sops.secrets.${secret} = { };
      sops.secrets.ai-admin-password = { };
      sops.templates.open-webui-env-file = {
        content = ''
          OAUTH_CLIENT_SECRET=${config.sops.placeholder.${secret}}
          WEBUI_ADMIN_PASSWORD=${config.sops.placeholder.ai-admin-password}
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

      # Limit file descriptors as this service is very resource-intensive
      systemd.services.open-webui.serviceConfig = {
        LimitNOFILE = 65536;
      };

      # Main Open WebUI service configuration
      services.open-webui = {
        enable = true;

        # Stable: unstable 0.12.3 fails, its `makeWrapperArgs` is one string that
        # structuredAttrs (now on by default in `buildPythonPackage`) no longer splits.
        package = lib.mkDefault openWebuiStable;
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
          OAUTH_CLIENT_ID = clientId;
          OPENID_PROVIDER_URL = oidc.openidConfigUrl;
          OAUTH_CODE_CHALLENGE_METHOD = "S256"; # PKCE -> https://docs.openwebui.com/reference/env-configuration#oauth_code_challenge_method

          # Auto-signup
          ENABLE_OAUTH_SIGNUP = "True";
          DEFAULT_USER_ROLE = "user"; # Not pending
          WEBUI_SESSION_COOKIE_SAME_SITE = "lax"; # https://docs.openwebui.com/reference/env-configuration#webui_session_cookie_same_site

          # Enable for setup... TODO: automatic, declarative
          # Configure what users see by default in groups -> permissions: models, etc.
          # Then for each model, make "public" those users have access to
          ENABLE_LOGIN_FORM = "True";
          ENABLE_PASSWORD_AUTH = "True";

          # Permissions
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
