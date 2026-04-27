# A full-configured lasuite-docs module.

{
  lib,
  dnfLib,
  config,
  network,
  zone,
  host,
  ...
}:
let
  cfg = config.darkone.service.docs;
  srvPort = 4445;
  srvInternalIp = "127.0.0.1";
  defaultParams = {
    title = "LaSuite Docs";
    description = "My Documents";
    icon = "docs-collaboration";
    ip = "127.0.0.1";
  };
  params = dnfLib.extractServiceParams host network "docs" defaultParams;
in
{
  options = {
    darkone.service.docs.enable = lib.mkEnableOption "Enable local docs service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.docs = {
        inherit defaultParams;
        persist.dirs = [ "/var/lib/lasuite-docs" ];
        proxy.servicePort = srvPort;
        proxy.extraConfig = ''
          root * ${cfg.frontendPackage}

          # Error pages
          handle_errors {
            @401 expression {http.error.status_code} == 401
            @403 expression {http.error.status_code} == 403
            @404 expression {http.error.status_code} == 404
            rewrite @401 /401
            rewrite @403 /403
            rewrite @404 /404
            file_server
          }

          # location ~ '^/docs/<uuid>/?$'
          @docs path_regexp ^/docs/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/?$
          handle @docs {
            try_files {path} /docs/[id]/index.html
            file_server
          }

          # location ~ '^/user-reconciliations/(active|inactive)/<uuid>/?$'
          # {re.recon.1} est l'équivalent de $1 pour le groupe capturé (active|inactive)
          @reconciliations path_regexp recon ^/user-reconciliations/(active|inactive)/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/?$
          handle @reconciliations {
            rewrite * /user-reconciliations/{re.recon.1}/[id]/index.html
            file_server
          }

          # WebSocket avant /collaboration/api/ (plus spécifique en premier)
          handle /collaboration/ws/* {
            reverse_proxy localhost:${toString cfg.collaborationServer.port}
          }

          handle /collaboration/api/* {
            reverse_proxy localhost:${toString cfg.collaborationServer.port}
          }

          # Endpoint d'auth (pour les requêtes directes)
          # Caddy forward_auth ne transmet pas le body nativement, idem pour proxy_pass_request_body off
          handle /media-auth {
            reverse_proxy http://${cfg.bind}/api/v1.0/documents/media-auth/ {
              header_up X-Original-URL    {uri}
              header_up X-Original-Method {method}
              header_up Content-Length    ""
            }
          }

          # Équivalent auth_request + proxy vers S3
          # forward_auth remplace auth_request : envoie la requête sans body à l'endpoint d'auth,
          # puis copy_headers copie les headers de la réponse d'auth sur la requête sortante vers S3
          handle /media/* {
            forward_auth http://${cfg.bind}/api/v1.0/documents/media-auth/ {
              header_up X-Original-URL    {uri}
              header_up X-Original-Method {method}
              header_up Content-Length    ""
              copy_headers Authorization X-Amz-Date X-Amz-Content-SHA256
            }
            header Content-Security-Policy "default-src 'none'"
            reverse_proxy ${cfg.s3Url}
          }

          # location /api — path /api couvre /api sans slash, /api/* couvre le reste
          @api path /api /api/*
          handle @api {
            reverse_proxy ${cfg.bind}
          }

          @admin path /admin /admin/*
          handle @admin {
            reverse_proxy ${cfg.bind}
          }

          # Fallback : fichiers statiques
          handle {
            file_server
          }
        '';
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.docs.enable = true;
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [ srvPort ];
      };

      #------------------------------------------------------------------------
      # docs Service
      #------------------------------------------------------------------------

      # OIDC Secret
      sops.secrets.oidc-secret-lasuite-docs = { };
      sops.templates.searx-env = {
        content = ''
          OIDC_RP_CLIENT_SECRET=${config.sops.placeholder.oidc-secret-lasuite-docs}
        '';
        mode = "0400";
        owner = "lasuite-docs";
        restartUnits = [ "lasuite-docs.service" ];
      };

      # Main service
      services.lasuite-docs = {
        enable = true;
        enableNginx = false;
        domain = params.fqdn;
        bind = "${srvInternalIp}:${srvPort}";
        redis.createLocally = true;
        postgresql.createLocally = true;
        settings = {
          LANGUAGE_CODE = zone.lang;
          DJANGO_ALLOWED_HOSTS = srvInternalIp;
          OIDC_OP_AUTHORIZATION_ENDPOINT = "https://idm.${zone.domain}/ui/oauth2";
          OIDC_OP_TOKEN_ENDPOINT = "https://idm.${zone.domain}/oauth2/token";
          OIDC_RP_CLIENT_ID = "lasuite-docs";
        };
        environmentFile = config.sops.templates.docs-env.path;
      };
    })
  ];
}
