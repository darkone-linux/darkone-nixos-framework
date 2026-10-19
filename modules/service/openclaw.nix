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
# - state: `/var/lib/openclaw` (provider logins, sessions, workspace).
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

  # Identities as oauth2-proxy forwards them: the members' Kanidm e-mails.
  memberEmails = map (u: users.${u}.email) (lib.filter (u: users ? ${u}) (dnfLib.spaceMembers host));
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
  ];
}
