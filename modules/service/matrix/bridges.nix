# DNF matrix: mautrix bridges. Doc: `../matrix.nix` header.

{
  lib,
  dnfConfig,
  config,
  network,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.matrix;
  inherit (cfg.shared) matrixAdmins;
  synapsePort = dnfConfig.network.ports.matrix;
  telegramPort = dnfConfig.network.ports.matrixTelegram;
  discordPort = dnfConfig.network.ports.matrixDiscord;

  # Mautrix settings shared by every bridge
  mautrixCommonSettings = {
    homeserver = {
      address = "http://localhost:${toString synapsePort}";
      domain = config.services.matrix-synapse.settings.server_name;
      verify_ssl = false;
    };
  };

  # Every local account may use a bridge with its own remote account; declared
  # admins get bridge administration. The user level differs per bridge
  # generation: bridgev2/go expect "user", legacy telegram needs "full" to
  # allow own-account login.
  mkBridgePermissions =
    userLevel:
    {
      "${network.domain}" = userLevel;
    }
    // lib.genAttrs (map (a: "@${a}:${network.domain}") matrixAdmins) (_: "admin");

  # Official appservice double puppeting: one shared as_token for all bridges,
  # substituted by envsubst from each bridge's environmentFile.
  doublePuppetSecret = "as_token:$MAUTRIX_DOUBLEPUPPET_AS_TOKEN";

  # Settings shared by the bridgev2 bridges (meta, whatsapp, signal). The legacy
  # telegram (python) and discord (go) bridges use a different schema and keep
  # their own blocks. Single point of truth for the encryption policy, which
  # otherwise had to be edited bridge by bridge.
  bridgev2Settings = {
    bridge.permissions = mkBridgePermissions "user";
    double_puppet.secrets."${network.domain}" = doublePuppetSecret;
    encryption = {
      allow = true;
      default = true;
      pickle_key = "$ENCRYPTION_PICKLE_KEY";
      require = false;

      # Mandatory with delegated auth; synapse forces it on every appservice
      msc4190 = true;
    };
  };

  # sops plumbing of a mautrix bridge: appservice tokens, optional pickle key,
  # env template read by the unit. `name`: sops namespace (`mautrix-<name>-*`)
  # and env prefix (`MAUTRIX_<NAME>_*`); `unit`/`owner` default to
  # `mautrix-<name>`, meta overrides them (instance name in its unit).
  mkBridgeSops =
    {
      name,
      unit ? "mautrix-${name}",
      owner ? unit,
      withPickleKey ? true,
      extraSecrets ? [ ],
    }:
    let
      envPrefix = "MAUTRIX_${lib.toUpper name}";

      # Secret suffix -> env var read by the bridge. The two appservice tokens
      # and the pickle key have names the bridges impose; anything else follows
      # the plain `<PREFIX>_<SUFFIX>` convention.
      envFor =
        suffix:
        {
          "as-token" = "${envPrefix}_APPSERVICE_AS_TOKEN";
          "hs-token" = "${envPrefix}_APPSERVICE_HS_TOKEN";
          "encryption-pickle-key" = "ENCRYPTION_PICKLE_KEY";
        }
        .${suffix} or "${envPrefix}_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] suffix)}";

      suffixes =
        extraSecrets
        ++ [
          "as-token"
          "hs-token"
        ]
        ++ lib.optional withPickleKey "encryption-pickle-key";

      secretName = suffix: "mautrix-${name}-${suffix}";
    in
    {
      sops.secrets = lib.genAttrs (map secretName suffixes) (_: { });

      sops.templates."mautrix-${name}-env" = {
        content =
          lib.concatMapStrings (
            suffix: "${envFor suffix}=${config.sops.placeholder.${secretName suffix}}\n"
          ) suffixes
          + "MAUTRIX_DOUBLEPUPPET_AS_TOKEN=${config.sops.placeholder.mautrix-doublepuppet-as-token}\n";
        mode = "0400";
        inherit owner;

        # TODO: WARN: restarting or reloading systemd units from the activation script is deprecated and will be removed in NixOS 26.11.
        restartUnits = [ "${unit}.service" ];
      };
    };
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {

      # Double puppeting appservice: a single shared as_token allows every
      # bridge to impersonate local users (official docs.mau.fi method). The
      # hs_token is required by synapse but never used.
      sops.secrets.mautrix-doublepuppet-as-token = { };
      sops.secrets.mautrix-doublepuppet-hs-token = { };
      sops.templates.doublepuppet-registration = {
        content = ''
          id: doublepuppet
          url:
          as_token: ${config.sops.placeholder.mautrix-doublepuppet-as-token}
          hs_token: ${config.sops.placeholder.mautrix-doublepuppet-hs-token}
          sender_localpart: doublepuppet
          rate_limited: false
          namespaces:
            users:
              - regex: '@.*:${network.domain}'
                exclusive: false
        '';
        mode = "0400";
        owner = "matrix-synapse";
        restartUnits = [ "matrix-synapse.service" ];
      };

      # Double puppeting appservice for the mautrix bridges (the bridges'
      # own registrations are appended by their nixpkgs modules)
      services.matrix-synapse.settings.app_service_config_files = [
        config.sops.templates.doublepuppet-registration.path
      ];

      # Used by mautrix bridges for conversions; olm is required by legacy
      # bridges and is flagged insecure upstream.
      environment.systemPackages = [ pkgs.ffmpeg_7 ];
      nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];
    })

    #------------------------------------------------------------------------
    # Mautrix bridge: Facebook Messenger (bridgev2)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.messenger.enable) (
      lib.mkMerge [
        (mkBridgeSops {
          name = "meta";
          unit = "mautrix-meta-messenger";
        })
        {

          services.mautrix-meta.instances.messenger = {
            enable = true;
            environmentFile = config.sops.templates.mautrix-meta-env.path;
            settings = mautrixCommonSettings // {
              network.mode = "messenger";
              network.chat_sync_max_age = "168h"; # only sync active conversations from the last 7 days
              inherit (bridgev2Settings) bridge double_puppet;

              # The nixpkgs mautrix-meta defaults are stricter than the other
              # bridges: `require = true` makes the bot ignore unencrypted rooms
              # and `cross-signed-tofu` silently drops messages from unverified
              # sessions — the bot never answers. Align on whatsapp/signal
              # (mautrix upstream defaults). Changing pickle_key from the module
              # default requires a bridge state reset (/var/lib/mautrix-meta-*).
              encryption = bridgev2Settings.encryption // {
                verification_levels = {
                  receive = "unverified";
                  send = "unverified";
                  share = "cross-signed-tofu";
                };

                # Aggressive key deletion is only sensible with enforced
                # verification; back to mautrix defaults like the other bridges.
                delete_keys = {
                  dont_store_outbound = false;
                  ratchet_on_decrypt = false;
                  delete_fully_used_on_decrypt = false;
                  delete_prev_on_new_session = false;
                  delete_on_device_delete = false;
                  periodically_delete_expired = false;
                  delete_outdated_inbound = false;
                };
              };
              appservice = {
                id = "messenger";

                # Deterministic registration tokens (cf. file header)
                as_token = "$MAUTRIX_META_APPSERVICE_AS_TOKEN";
                hs_token = "$MAUTRIX_META_APPSERVICE_HS_TOKEN";
                bot = {
                  username = "messengerbot";
                  displayname = "Messenger bridge bot";
                  avatar = "mxc://maunium.net/ygtkteZsXnGJLJHRchUwYWak";
                };
              };
            };
          };
        }
      ]
    ))

    #------------------------------------------------------------------------
    # Mautrix bridge: WhatsApp (bridgev2)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.whatsapp.enable) (
      lib.mkMerge [
        (mkBridgeSops { name = "whatsapp"; })
        {

          services.mautrix-whatsapp = {
            enable = true;
            environmentFile = config.sops.templates.mautrix-whatsapp-env.path;
            settings = lib.mkMerge [
              mautrixCommonSettings
              bridgev2Settings
              {

                # Deterministic registration tokens (cf. file header)
                appservice = {
                  as_token = "$MAUTRIX_WHATSAPP_APPSERVICE_AS_TOKEN";
                  hs_token = "$MAUTRIX_WHATSAPP_APPSERVICE_HS_TOKEN";
                };

                # Do not bridge WhatsApp statuses: the default (true) keeps
                # re-inviting every user to a "WhatsApp Status Broadcast" room.
                network.enable_status_broadcast = false;
              }
            ];
          };
        }
      ]
    ))

    #------------------------------------------------------------------------
    # Mautrix bridge: Signal (bridgev2)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.signal.enable) (
      lib.mkMerge [
        (mkBridgeSops { name = "signal"; })
        {

          services.mautrix-signal = {
            enable = true;
            environmentFile = config.sops.templates.mautrix-signal-env.path;
            settings = lib.mkMerge [
              mautrixCommonSettings
              bridgev2Settings
              {

                # Deterministic registration tokens (cf. file header)
                appservice = {
                  as_token = "$MAUTRIX_SIGNAL_APPSERVICE_AS_TOKEN";
                  hs_token = "$MAUTRIX_SIGNAL_APPSERVICE_HS_TOKEN";
                };
              }
            ];
          };
        }
      ]
    ))

    #------------------------------------------------------------------------
    # Mautrix bridge: Telegram (legacy python bridge)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.telegram.enable) (
      lib.mkMerge [

        # No pickle key: the legacy bridge keeps its olm state in its own DB.
        # API credentials -> https://my.telegram.org/
        (mkBridgeSops {
          name = "telegram";
          withPickleKey = false;
          extraSecrets = [
            "api-id"
            "api-hash"
          ];
        })
        {

          services.mautrix-telegram = {
            enable = true;
            environmentFile = config.sops.templates.mautrix-telegram-env.path;
            settings = lib.mkMerge [
              mautrixCommonSettings
              {
                telegram = {
                  api_id = "$MAUTRIX_TELEGRAM_API_ID";
                  api_hash = "$MAUTRIX_TELEGRAM_API_HASH";
                  bot_token = "disabled";
                };
                appservice = {
                  id = "telegram";
                  address = "http://localhost:${toString telegramPort}"; # 8080 by default already in use
                  port = telegramPort;
                  as_token = "$MAUTRIX_TELEGRAM_APPSERVICE_AS_TOKEN";
                  hs_token = "$MAUTRIX_TELEGRAM_APPSERVICE_HS_TOKEN";
                };
                bridge = {

                  # Legacy levels: "full" (not "user") is required so that local
                  # accounts can log into their own telegram account.
                  permissions = mkBridgePermissions "full";
                  login_shared_secret_map."${network.domain}" = doublePuppetSecret;
                  encryption = {
                    allow = true;
                    default = true;
                    msc4190 = true;
                    require = false;
                  };
                };
              }
            ];
          };
        }
      ]
    ))

    #------------------------------------------------------------------------
    # Mautrix bridge: Discord (legacy go bridge, optional)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.discord.enable) (
      lib.mkMerge [

        # No pickle key: the legacy bridge keeps its olm state in its own DB.
        (mkBridgeSops {
          name = "discord";
          withPickleKey = false;
        })
        {

          services.mautrix-discord = {
            enable = true;
            environmentFile = config.sops.templates.mautrix-discord-env.path;
            settings = {
              homeserver = mautrixCommonSettings.homeserver;

              # Deterministic registration tokens (cf. file header). The module's
              # appservice option is a non-merging attrs: setting the tokens
              # replaces its default wholesale, so the upstream values must be
              # restated here.
              appservice = {
                address = "http://localhost:${toString discordPort}";
                hostname = "0.0.0.0";
                port = discordPort;
                database = {
                  type = "sqlite3";
                  uri = "file:/var/lib/mautrix-discord/mautrix-discord.db?_txlock=immediate";
                  max_open_conns = 20;
                  max_idle_conns = 2;
                  max_conn_idle_time = null;
                  max_conn_lifetime = null;
                };
                id = "discord";
                bot = {
                  username = "discordbot";
                  displayname = "Discord bridge bot";
                  avatar = "mxc://maunium.net/nIdEykemnwdisvHbpxflpDlC";
                };
                ephemeral_events = true;
                async_transactions = false;
                as_token = "$MAUTRIX_DISCORD_APPSERVICE_AS_TOKEN";
                hs_token = "$MAUTRIX_DISCORD_APPSERVICE_HS_TOKEN";
              };

              # Intentionally partial: missing keys (templates, command prefix...)
              # are filled at startup by the bridge's embedded config upgrader.
              bridge = {
                permissions = mkBridgePermissions "user" // {
                  "*" = "relay";
                };
                login_shared_secret_map."${network.domain}" = doublePuppetSecret;

                # Mandatory with delegated auth (cf. `mas.nix`)
                encryption.msc4190 = true;
              };
            };
          };
        }
      ]
    ))
  ];
}
