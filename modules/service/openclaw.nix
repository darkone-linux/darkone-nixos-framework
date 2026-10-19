# OpenClaw assistant of an AI space (gateway + control UI, behind the zone SSO).
#
# One instance per `ai-space` host, declared like any service:
#
# ```yaml
# - hostname: "ia-pro"
#   profile: "ai-space"
#   users: ["alice"]          # members: Kanidm group `space-ia-pro`
#   services: { openclaw: {} }
# ```
#
# - access: Caddy forward auth, members of `space-<host>` only
#   (`proxy.spaceMembersOnly`); OpenClaw trusts the zone gateway as proxy
#   (`trusted-proxy`) and reads the identity from `x-auth-request-email`;
# - devices: a member's browser is paired on first visit, without operator
#   admin (granted from the host CLI only);
# - port: reachable from the zone gateway only;
# - state: `/var/lib/openclaw` (provider logins, sessions, workspace,
#   Matrix E2EE keys);
# - Matrix: DM channel with the bot `@<host>:<domain>`, members only, when the
#   network has Matrix and `just space-init <host>` created the bot (marker
#   `var/generated/spaces/<host>.nix`, token in the space's sops file); exec
#   approvals asked to members in DM.
#
# :::note[Provider logins]
# Once per space, from the host: `sudo -u openclaw openclaw models auth login
# --provider openai-codex` (ChatGPT), or another provider. Tokens stay in the state.
# :::

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  options,
  pkgs,
  host,
  zone,
  network,
  users,
  workDir,
  ...
}:
let
  cfg = config.darkone.service.openclaw;
  port = dnfConfig.network.ports.openclaw;
  stateDir = "/var/lib/openclaw";
  defaultParams = {
    title = "Assistant IA";
    description = "Agent personnel de l'espace";
    icon = "mdi-robot";
  };
  params = dnfLib.extractServiceParams host network "openclaw" defaultParams;
  gatewayIp = zone.gateway.lan.ip;

  # Host CLI on the service's config and state: `sudo -u openclaw openclaw …`.
  cli = pkgs.writeShellScriptBin "openclaw" ''
    export OPENCLAW_CONFIG_PATH=${config.services.openclaw-gateway.configPath or ""}
    export OPENCLAW_STATE_DIR=${stateDir}
    exec ${pkgs.openclaw-gateway}/bin/openclaw "$@"
  '';

  members = lib.filter (u: users ? ${u}) (dnfLib.spaceMembers host);

  # Identities as oauth2-proxy forwards them: the members' Kanidm e-mails.
  memberEmails = map (u: users.${u}.email) members;

  # Matrix channel: on once the bot exists (`just space-init`), so a deploy
  # never asks sops for a token not yet issued; off without a network Matrix,
  # whatever a stale marker says.
  botFile = workDir + "/var/generated/spaces/${host.hostname}.nix";
  matrixBot = if builtins.pathExists botFile then (import botFile).matrixBot else null;
  networkHasMatrix = lib.any (s: s.name == "matrix") network.services;
  hasMatrix = matrixBot != null && networkHasMatrix;
  memberMxids = map (u: "@${u}:${network.domain}") members;
  tokenEnv = "OPENCLAW_MATRIX_TOKEN";

  matrixConfig = {
    plugins = {
      load.paths = [ "${pkgs.openclaw-runtime-plugin-matrix}" ];
      entries.matrix.enabled = true;
    };
    channels.matrix = {
      enabled = true;
      homeserver = "https://matrix.${network.domain}";
      userId = "@${matrixBot}:${network.domain}";
      accessToken = {
        source = "env";
        provider = "default";
        id = tokenEnv;
      };
      encryption = true;

      # Joins any invite, answers members only (DMs and rooms).
      autoJoin = "always";
      dm = {
        enabled = true;
        policy = "allowlist";
        allowFrom = memberMxids;
      };
      groupPolicy = "allowlist";
      groupAllowFrom = memberMxids;
      execApprovals = {
        enabled = true;
        approvers = memberMxids;
        target = "dm";
      };
    };
  };
in
{
  options = {
    darkone.service.openclaw.enable = lib.mkEnableOption "Enable the OpenClaw assistant of an AI space";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.openclaw = {
        inherit defaultParams;
        persist.dirs = [ stateDir ];
        proxy.servicePort = port;
        proxy.spaceMembersOnly = true;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "openclaw";

      # `services.openclaw-gateway` exists on `ai-space` hosts only
      # (`lib/mk-configuration.nix`).
      assertions = [
        {
          assertion = options ? services.openclaw-gateway;
          message = "${host.hostname}: the openclaw service runs on an `ai-space` host only.";
        }
      ];
      warnings = lib.optional (memberEmails == [ ]) (
        "${host.hostname}: openclaw without members (`users` of the host): nobody passes the SSO."
      );

      # Gateway only: Caddy is the sole client, `trusted-proxy` relies on it.
      networking.firewall.extraInputRules = ''
        ip saddr ${gatewayIp} tcp dport ${toString port} accept
      '';
    })

    #------------------------------------------------------------------------
    # OpenClaw gateway
    #------------------------------------------------------------------------

    (lib.optionalAttrs (options ? services.openclaw-gateway) (
      lib.mkIf cfg.enable {
        environment.systemPackages = [ cli ];
        services.openclaw-gateway = {
          enable = true;
          package = pkgs.openclaw-gateway;
          inherit port stateDir;
          config.gateway = {
            mode = "local";

            # Non-loopback: `trusted-proxy` rejects a proxy on the same host.
            bind = "lan";
            trustedProxies = [ gatewayIp ];
            publicOrigin = params.href;
            auth = {
              mode = "trusted-proxy";
              trustedProxy = {
                userHeader = "x-auth-request-email";
                allowUsers = memberEmails;

                # The SSO is the enrollment boundary: no admin scope here.
                deviceAutoApprove = {
                  enabled = true;
                  scopes = [
                    "operator.read"
                    "operator.write"
                    "operator.approvals"
                    "operator.questions"
                  ];
                };
              };
            };
          };
        };
      }
    ))

    #------------------------------------------------------------------------
    # Matrix channel
    #------------------------------------------------------------------------

    (lib.optionalAttrs (options ? services.openclaw-gateway) (
      lib.mkIf (cfg.enable && hasMatrix) {

        # sops-nix files are symlinks, which OpenClaw's file provider rejects:
        # the token reaches it as an environment variable.
        sops.secrets.openclaw-matrix-token = { };
        sops.templates."openclaw-gateway.env" = {
          content = "${tokenEnv}=${config.sops.placeholder.openclaw-matrix-token}\n";
          owner = "openclaw";
        };

        services.openclaw-gateway = {
          environmentFiles = [ config.sops.templates."openclaw-gateway.env".path ];

          # Plugins by store path: the persisted registry would shadow them.
          environment.OPENCLAW_DISABLE_PERSISTED_PLUGIN_REGISTRY = "1";
          config = matrixConfig;
        };
      }
    ))
  ];
}
