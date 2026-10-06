# DNF matrix: authentication delegated to MAS. Doc: `../matrix.nix` header.

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  network,
  hosts,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.matrix;
  srv = config.services.matrix-synapse;
  inherit (cfg.shared) params masKanidmUlid matrixAdmins;
  synapsePort = dnfConfig.network.ports.matrix;
  masPort = dnfConfig.network.ports.matrixAuth;

  # Sops files are root-owned and MAS runs with DynamicUser: LoadCredential
  # bridges the gap. Absolute form of systemd's %d, usable in MAS settings.
  masCreds = "/run/credentials/matrix-authentication-service.service";

  # Secret name -> sops path, shared by the unit credentials and the CLI
  # wrapper so both expose the very same file names under their creds dir.
  masCredFiles = {
    encryption = config.sops.secrets.mas-encryption-secret.path;
    rsa-key = config.sops.secrets.mas-rsa-private-key.path;
    synapse-secret = config.sops.secrets.mas-synapse-secret.path;
    oidc-client-secret = config.sops.secrets.${secret}.path;
  };

  # The unit config lives in a RuntimeDirectory that disappears with the
  # service, and its credentials are unreadable outside it: regenerate an
  # equivalent file so `mas-cli` keeps working while MAS is stopped (which
  # syn2mas requires). Built from the evaluated option, module defaults
  # (database uri, trusted proxies...) included.
  masCliConfig = (pkgs.formats.yaml { }).generate "mas-cli-config.yaml" (
    config.services.matrix-authentication-service.settings
  );

  # syn2mas refuses to map the `oidc-kanidm` external ids unless synapse still
  # declares that provider, which delegated mode precisely removes. Hand the
  # legacy block back as an extra synapse config: read for provider ids only,
  # so the client secret is never used.
  syn2masOidcConfig = (pkgs.formats.yaml { }).generate "syn2mas-oidc.yaml" {
    oidc_providers = [
      {
        idp_id = "kanidm";
        idp_name = "IDM";
        issuer = oidc.issuerUrl;
        client_id = clientId;
        client_secret = "unused-by-syn2mas";
        scopes = [
          "openid"
          "profile"
        ];
        user_mapping_provider.config = {
          localpart_template = "{{ user.preferred_username.split('@')[0] | lower }}";
          display_name_template = "{{ user.displayname }}";
        };
      }
    ];
  };

  # Postgres only accepts peer auth here, and syn2mas needs both the MAS and
  # the synapse database at once: `postgres` is the single local identity that
  # reaches both. Root reads the sops files, hands them over, then drops to it.
  masCliUser = "postgres";
  masCliScript = pkgs.writeShellApplication {
    name = "dnf-mas";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.util-linux
      config.services.matrix-authentication-service.package
    ];
    text = ''
      if [ "$(id -u)" != 0 ] ;then
        echo "dnf-mas: must run as root (reads the sops secrets)." >&2
        exit 1
      fi

      # mas-cli looks for a .env in its cwd; a caller's $HOME is unreadable
      # once we drop to ${masCliUser} and only yields a warning.
      cd /

      # Private creds dir mirroring the unit's, wiped on exit.
      creds="$(mktemp -d /run/dnf-mas.XXXXXX)"
      trap 'rm -rf "$creds"' EXIT
      chown ${masCliUser} "$creds"
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          name: path: ''install -o ${masCliUser} -m 0400 ${path} "$creds/${name}"''
        ) masCredFiles
      )}
      sed 's|${masCreds}|'"$creds"'|g' ${masCliConfig} > "$creds/config.yaml"
      chown ${masCliUser} "$creds/config.yaml"

      # syn2mas needs synapse's own config plus the legacy provider block, and
      # its database uri would carry the `matrix-synapse` role that peer auth
      # denies us: inject all three so the operator works them out never.
      if [ "''${1:-}" = "syn2mas" ] && [[ "$*" != *--synapse-config* ]] ;then
        shift
        set -- syn2mas \
          --synapse-config "${srv.configFile}" \
          --synapse-config "${syn2masOidcConfig}" \
          --synapse-database-uri "postgresql:///${srv.settings.database.args.database}?host=/run/postgresql" \
          "$@"
      fi

      # Not `exec`: that would replace the shell and drop the EXIT trap,
      # leaving the decrypted secrets behind in /run after every run.
      status=0
      runuser -u ${masCliUser} -- mas-cli --config "$creds/config.yaml" "$@" || status=$?
      exit "$status"
    '';
  };

  inherit
    (dnfLib.mkOidcContext {
      name = "matrix";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;
in
{
  imports = [

    # Auth is delegated to MAS unconditionally: a leftover `false` would have
    # silently kept a homeserver on deprecated synapse auth.
    (lib.mkRemovedOptionModule [ "darkone" "service" "matrix" "mas" "enable" ]
      "MAS is always enabled. A pre-MAS homeserver must run the syn2mas migration (cf. dnf/modules/service/matrix/mas.nix header)."
    )
  ];

  config = lib.mkIf cfg.enable {

    # Kanidm client secret: read by MAS as a credential, never by synapse.
    sops.secrets.${secret} = { };

    # Immutable after first start (cf. header)
    sops.secrets.mas-encryption-secret.restartUnits = [ "matrix-authentication-service.service" ];

    # OIDC token signing keys (PEM)
    sops.secrets.mas-rsa-private-key.restartUnits = [ "matrix-authentication-service.service" ];

    # Shared MAS <-> synapse secret: synapse reads the file directly
    # (`secret_path`), MAS gets it as a root-read credential.
    sops.secrets.mas-synapse-secret = {
      mode = "0400";
      owner = "matrix-synapse";
      restartUnits = [
        "matrix-authentication-service.service"
        "matrix-synapse.service"
      ];
    };

    services.matrix-authentication-service = {
      enable = true;
      createDatabase = true;

      # Sops files are root-only and the unit runs with DynamicUser; the
      # module's own option is used rather than a hand-written
      # `serviceConfig.LoadCredential`, which would collide with it.
      credentials = masCredFiles;

      settings = {
        http.public_base = params.href + "/";
        http.listeners = [
          {
            name = "web";
            resources = [
              { name = "discovery"; }
              { name = "human"; }
              { name = "oauth"; }
              { name = "compat"; }
              { name = "graphql"; }

              # `/api/admin/*`, gated by the `urn:mas:admin` scope: what the
              # `matrix-admin` UI reads. Absent, its login still succeeds and
              # every MAS panel (sessions, tokens, emails) then fails.
              { name = "adminapi"; }
              { name = "assets"; }
              { name = "health"; }
            ];
            binds = [
              {
                host = params.ip;
                port = masPort;
              }
            ];
          }
        ];

        # Token introspection + user provisioning against synapse, over
        # loopback (both live on the same host, like the Caddy routes).
        matrix = {
          kind = "synapse";
          homeserver = srv.settings.server_name;
          endpoint = "http://localhost:${toString synapsePort}";
          secret_file = "${masCreds}/synapse-secret";
        };

        secrets = {
          encryption_file = "${masCreds}/encryption";
          keys = [
            {
              kid = "dnf-rsa";
              key_file = "${masCreds}/rsa-key";
            }
          ];
        };

        # bcrypt v1 mirrors the synapse hashes imported by syn2mas
        # (upgraded to argon2id on next login); harmless on a fresh
        # install where no v1 hash ever exists.
        passwords = {
          enabled = true;
          schemes = [
            {
              version = 1;
              algorithm = "bcrypt";
              unicode_normalization = true;
            }
            {
              version = 2;
              algorithm = "argon2id";
            }
          ];
        };

        # friendRegistration parity: token-gated local password accounts.
        # No email requirement: the stack has no user-facing SMTP.
        account = {
          password_registration_enabled = cfg.friendRegistration.enable;
          password_registration_token_required = cfg.friendRegistration.enable;
          password_registration_email_required = false;
        };

        # Declarative server administration: the bundled policy turns these
        # local parts into `urn:mas:admin` + `urn:synapse:admin:*`, so no
        # `promote-admin` and no database write (cf. `../matrix.nix`).
        policy.data.admin_users = matrixAdmins;

        upstream_oauth2.providers = [
          {
            id = masKanidmUlid;
            human_name = "IDM";
            issuer = oidc.issuerUrl;
            client_id = clientId;
            client_secret_file = "${masCreds}/oidc-client-secret";
            scope = "openid profile";
            token_endpoint_auth_method = "client_secret_basic";

            # Kanidm signs id_tokens with ES256 and advertises nothing else
            # (RS256 would need its legacy crypto mode). MAS defaults to
            # RS256 and rejects the callback with "wrong signature alg",
            # which breaks every fresh SSO login.
            id_token_signed_response_alg = "ES256";

            # syn2mas maps the synapse-era external ids through this key
            # (synapse `idp_id = "kanidm"` -> `oidc-kanidm`)
            synapse_idp_id = "oidc-kanidm";
            claims_imports = {

              # Must yield the same localparts as the legacy synapse
              # `localpart_template` (account continuity across migration)
              localpart = {
                action = "require";
                template = "{{ user.preferred_username | split('@') | first | lower }}";
              };
              displayname = {
                action = "suggest";
                template = "{{ user.name }}";
              };
            };
          }
        ];
      };
    };

    # Host-side administration (registration tokens, admin, syn2mas)
    environment.systemPackages = [ masCliScript ];

    # Synapse in delegated mode: every auth decision goes through MAS
    services.matrix-synapse.settings.matrix_authentication_service = {
      enabled = true;
      endpoint = "http://localhost:${toString masPort}/";
      secret_path = config.sops.secrets.mas-synapse-secret.path;
    };

    # MAS notifies `READY=1` once its listeners are bound (sd-notify): with
    # `Type=notify`, synapse's `after` waits for a listening MAS, even
    # through slow migrations after an upgrade.
    systemd.services.matrix-authentication-service.serviceConfig.Type = "notify";

    # Delegated auth needs MAS up before synapse serves clients. `wants`, not
    # `requires`: a MAS restart must not take synapse down with it.
    systemd.services.matrix-synapse = {
      after = [ "matrix-authentication-service.service" ];
      wants = [ "matrix-authentication-service.service" ];
    };

    # Upstream default orders MAS after synapse (appservice boilerplate), the
    # reverse of the above: an ordering cycle. MAS never calls synapse at
    # startup (lazy homeserver connection), so the default is dropped.
    services.matrix-authentication-service.serviceDependencies = [ ];

    # QR-code login ("link a new device", required by Element X). MSC4108
    # adds synapse's rendezvous channel, which pairs with the device
    # authorization grant MAS already exposes; without it clients report
    # "your account provider does not support QR code sign-in". Synapse
    # refuses the flag unless auth is delegated, hence this block.
    services.matrix-synapse.settings.experimental_features.msc4108_enabled = true;
  };
}
