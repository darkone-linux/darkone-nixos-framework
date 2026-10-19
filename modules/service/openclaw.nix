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
#   approvals asked to members in DM;
# - agent tooling: MCP, skills, Claude Code / Codex and `packages` of the
#   space (`darkone.host.ai-space`), shared with the members' homes;
# - workspace (`/var/lib/openclaw/workspace`): `workspace` files (AGENTS.md,
#   SOUL.md...) replaced at each start, others left to the agent; `projects`
#   git-cloned once into `projects/<name>`;
# - voice notes: local whisper.cpp (`transcription`, ggml `small` model).
#
# ```nix
# darkone.service.openclaw = {
#   workspace."AGENTS.md" = ./agents/AGENTS.md;
#   projects.notes = "git@forge.example.com:alice/notes.git";
# };
# ```
#
# :::note[Provider logins]
# Once per space, from the host: `sudo -u openclaw openclaw models auth login
# --provider openai-codex` (ChatGPT), or another provider. Tokens stay in the state.
# Delegated CLIs log in the same way: `sudo -u openclaw -H claude` (`/login`),
# `sudo -u openclaw -H codex login --device-auth`.
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
  space = config.darkone.host.ai-space;
  workspaceDir = "${stateDir}/workspace";

  # Agent PATH: shell basics, the space's tools, the delegated coding CLIs.
  agentTools = [
    pkgs.git
    pkgs.curl
    pkgs.jq
    pkgs.ripgrep
  ]
  ++ space.packages
  ++ lib.optional space.enableClaude pkgs.claude-code-nix
  ++ lib.optional space.enableCodex pkgs.codex;

  # OpenClaw rejects null or empty fields its schema types otherwise.
  compact = lib.filterAttrs (_: v: v != null && v != [ ] && v != { });

  # One directory per skill (`<name>/SKILL.md`), real files: OpenClaw checks
  # symlink targets. A string is inline content, anything else a path.
  skillsDir = pkgs.runCommand "openclaw-space-skills" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatLines (
      lib.mapAttrsToList (
        name: skill:
        let
          src = if builtins.isString skill then pkgs.writeText "${name}-SKILL.md" skill else skill;
          dst = "$out/${lib.escapeShellArg name}";
        in
        ''
          if [ -d ${src} ]; then cp -rL ${src} ${dst}; else install -Dm644 ${src} ${dst}/SKILL.md; fi
        ''
      ) space.skills
    )
  );

  # Declared workspace files, replaced at each start (as `openclaw`).
  installWorkspace = pkgs.writeShellScript "openclaw-workspace" (
    lib.concatLines (
      lib.mapAttrsToList (
        name: file:
        let
          src = if builtins.isString file then pkgs.writeText "openclaw-${baseNameOf name}" file else file;
        in
        "${pkgs.coreutils}/bin/install -D -m 644 ${src} ${lib.escapeShellArg "${workspaceDir}/${name}"}"
      ) cfg.workspace
    )
  );

  # Matrix voice notes are Opus: whisper.cpp reads WAV, ffmpeg converts.
  transcribe = pkgs.writeShellScript "openclaw-transcribe" ''
    set -euo pipefail
    wav="$(${pkgs.coreutils}/bin/mktemp --suffix=.wav)"
    trap '${pkgs.coreutils}/bin/rm -f "$wav"' EXIT
    ${pkgs.ffmpeg-headless}/bin/ffmpeg -nostdin -loglevel error -y -i "$1" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"
    ${pkgs.whisper-cpp}/bin/whisper-cli -m ${cfg.transcription.model} \
      -l ${lib.escapeShellArg cfg.transcription.language} -nt -np -f "$wav"
  '';

  # Explicit CLI model: auto-detection prefers any provider holding auth.
  transcriptionConfig = {
    tools.media = {
      audio.enabled = true;
      models = [
        {
          type = "cli";
          command = "${transcribe}";
          args = [ "{{AttachmentPath}}" ];
          capabilities = [ "audio" ];
          timeoutSeconds = 180;
        }
      ];
    };
  };

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
    darkone.service.openclaw = {
      enable = lib.mkEnableOption "Enable the OpenClaw assistant of an AI space";

      workspace = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
        default = { };
        example = lib.literalExpression ''{ "AGENTS.md" = ./AGENTS.md; "SOUL.md" = "Tu es concis."; }'';
        description = ''
          Files of the agent workspace, by relative path: content or file.
          Replaced at each gateway start; undeclared files belong to the agent.
        '';
      };

      projects = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          notes = "https://forge.example.com/alice/notes.git";
        };
        description = ''
          Git repositories cloned once into `workspace/projects/<name>`, never
          pulled. SSH remotes use the key of `openclaw` (`/var/lib/openclaw/.ssh`).
        '';
      };

      transcription = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Transcribe voice notes locally (whisper.cpp, CPU).";
        };
        model = lib.mkOption {
          type = lib.types.path;
          default = pkgs.fetchurl {
            url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin";
            sha256 = "0ywqxbziyp2bv72riyjpw4brk9v46d4cfbjfwqvvjrrq0srakqqv";
          };
          defaultText = lib.literalMD "whisper.cpp ggml `small` model (466 MB)";
          description = "whisper.cpp ggml model.";
        };
        language = lib.mkOption {
          type = lib.types.str;
          default = "auto";
          example = "fr";
          description = "Spoken language (`auto`: detected per note).";
        };
      };
    };
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

        # Delegated CLIs on the system PATH too: their logins run from a shell.
        environment.systemPackages = [ cli ] ++ agentTools;
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
    # Agent tooling and workspace
    #------------------------------------------------------------------------

    (lib.optionalAttrs (options ? services.openclaw-gateway) (
      lib.mkIf cfg.enable {
        services.openclaw-gateway = {
          servicePath = agentTools;
          execStartPre = lib.optional (cfg.workspace != { }) "${installWorkspace}";

          # Pinned: the default follows `$HOME`, not the state dir.
          config = lib.mkMerge [
            { agents.defaults.workspace = workspaceDir; }
            (lib.mkIf (space.mcp != { }) { mcp.servers = lib.mapAttrs (_: compact) space.mcp; })
            (lib.mkIf (space.skills != { }) { skills.load.extraDirs = [ "${skillsDir}" ]; })
            (lib.mkIf cfg.transcription.enable transcriptionConfig)
          ];
        };

        # Best effort: a remote not reachable yet (key, network) is logged and
        # retried at the next boot, it never fails the deploy.
        systemd.services.openclaw-projects = lib.mkIf (cfg.projects != { }) {
          description = "Clone the projects of the OpenClaw workspace";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          environment.GIT_SSH_COMMAND = "${pkgs.openssh}/bin/ssh";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "openclaw";
            Group = "openclaw";
          };
          script = lib.concatLines (
            lib.mapAttrsToList (
              name: url:
              let
                dir = lib.escapeShellArg "${workspaceDir}/projects/${name}";
              in
              ''
                [ -d ${dir}/.git ] || ${pkgs.git}/bin/git clone ${lib.escapeShellArg url} ${dir} \
                  || echo "openclaw-projects: ${name} not cloned (${url})" >&2
              ''
            ) cfg.projects
          );
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
