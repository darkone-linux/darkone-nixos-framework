# OpenClaw assistant of an AI space (gateway + control UI, behind the zone SSO).
#
# One instance per `ai-space` host, declared like any service:
#
# ```yaml
# - hostname: "ia-pro"
#   profile: "ai-space"
#   users: ["alice"]          # members: Kanidm group `space-ia-pro`
#   features: ["monitoring-node"] # alerts: space down, gateway unit failed
#   services: { openclaw: {} }
# ```
#
# - access: Caddy forward auth, members of `space-<host>` only
#   (`proxy.spaceMembersOnly`); OpenClaw trusts the zone gateway as proxy
#   (`trusted-proxy`) and reads the identity from `x-auth-request-email`;
# - devices: a member's browser is paired on first visit, without operator
#   admin (granted from the host CLI only);
# - port: reachable from the zone gateway only;
# - host CLI: `openclaw` (alone: the TUI), re-run as the service user, past
#   `trusted-proxy` with the gateway password (`openclaw-gateway-password`,
#   `just space-init`); admins and `cliUsers` (default: the owner) only;
# - state: `/var/lib/openclaw` (provider logins, sessions, workspace,
#   Matrix E2EE keys);
# - owner (`owner`, default: the only member): its subscription runs the
#   agent, it gets approval requests and proactive messages;
# - Matrix: DM channel with the bot `@<host>:<domain>`, members only, rooms
#   ignored, one session per member when several, when the network has
#   Matrix and `just space-init <host>` created the bot (marker
#   `var/generated/spaces/<host>.nix`, token in the space's sops file); exec
#   approvals asked to the owner in DM;
# - agent tooling: MCP, skills, Claude Code / Codex / OpenCode and `packages`
#   of the space (`darkone.host.ai-space`), shared with the members' homes;
# - identity (`identity`: name, emoji, avatar): declared, the config being
#   read-only (`openclaw agents set-identity` fails);
# - `mutableConfig`: config writable from the UI and the CLI, Nix keys merged
#   at each start (imposed: access, channels, plugins, store paths; seeded
#   once: model, exec, identity...), owner gets `operator.admin`;
# - workspace (`/var/lib/openclaw/workspace`): `workspace` files (AGENTS.md,
#   SOUL.md...) replaced at each start, others left to the agent;
# - projects: the space's shared `projectsDir` is the agent's working dir
#   (`agents.defaults.cwd`), `projects` git-cloned once into it;
# - coding agents (Claude Code, Codex, OpenCode of the space): background
#   workers (`coding-agent` skill), chat-bound sessions (`/acp spawn`, acpx);
# - Talk (`talk`): live voice conversation in the browser, OpenAI GPT-Live,
#   work delegated to the agent (`agent-consult`), ChatGPT login first;
# - workflows: Lobster pipelines (`lobster`, `.lobster` files through
#   `workspace`), declared automations (`automations`, kept in sync, others
#   left to the agent and the UI);
# - voice notes: whisper.cpp (`transcription`); on a microVM guest the
#   hypervisor's server (`large-v3-turbo`), local ggml `small` as fallback;
#   local only on bare metal.
#
# ```nix
# darkone.service.openclaw = {
#   workspace."AGENTS.md" = ./agents/AGENTS.md;
#   projects.notes = "git@forge.example.com:alice/notes.git";
# };
# ```
#
# :::caution[Commands run without approval by default]
# `exec = "full"` (OpenClaw's default): the agent runs any command as
# `openclaw`, the space's tokens within reach. The microVM is the boundary,
# the hardened unit a second wall (writes to the state only). `ask`, `auto`:
# misses go to the owner, a guard against mistakes, not a wall (same user).
# :::
#
# :::note[Members trust each other]
# One gateway, one operator domain: every member's UI shows every session,
# DMs included. Members who do not trust each other get separate spaces.
# :::
#
# Models: `model` + `extraModels` (`/model` in the chat), the owner's
# `subscriptions` first, else an API key (`apiKeys`, sops `openclaw/<VAR>`);
# `providers` adds OpenAI-compatible endpoints (Nous Portal...).
#
# :::note[Provider login]
# Once per space, from the host as `nix` (the `openclaw` CLI re-runs itself as
# the service user, also for `cliUsers`), by subscription. Logins stay in the
# state.
# - `anthropic`: `sudo -u openclaw -H claude auth login`;
# - `openai`: `openclaw models auth login --provider openai`.
# :::

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  options,
  pkgs,
  host,
  hosts,
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
    description = "Agent OpenClaw";
  };
  params = dnfLib.extractServiceParams host network "openclaw" defaultParams;
  gatewayIp = zone.gateway.lan.ip;

  # Secrets of the gateway environment, rendered by sops-nix.
  envFile = config.sops.templates."openclaw-gateway.env".path;

  # Host CLI on the service's state, run as `openclaw`. The gateway password
  # lets it past `trusted-proxy`; bare `openclaw` (setup routing) ignores it,
  # `tui` reads it.
  cliRun = pkgs.writeShellScript "openclaw-cli" ''
    [ $# -eq 0 ] && set -- tui
    set -a
    . ${envFile}
    set +a
    export OPENCLAW_CONFIG_PATH=${configPath}
    export OPENCLAW_STATE_DIR=${stateDir}
    ${lib.optionalString cfg.mutableConfig "export OPENCLAW_NIX_MODE=0"}
    exec ${pkgs.openclaw-gateway}/bin/openclaw "$@"
  '';

  # Admins and `cliUsers` reach `cliRun` through sudo; other members, without
  # sudo, would face a password prompt.
  cliDenied = lib.subtractLists cfg.cliUsers members;
  cli = pkgs.writeShellScriptBin "openclaw" ''
    case "$(${pkgs.coreutils}/bin/id -un)" in
      openclaw) exec ${cliRun} "$@" ;;
      ${lib.optionalString (cliDenied != [ ]) ''
        ${lib.concatStringsSep "|" cliDenied})
          echo "openclaw: host CLI reserved to darkone.service.openclaw.cliUsers; use ${params.href}" >&2
          exit 1 ;;
      ''}
    esac
    exec /run/wrappers/bin/sudo -u openclaw -H ${cliRun} "$@"
  '';

  # Mutable: a state file, the store one (`/etc`) stays as reference.
  configPath =
    if cfg.mutableConfig then
      "${stateDir}/openclaw.json"
    else
      config.services.openclaw-gateway.configPath or "";

  members = lib.filter (u: users ? ${u}) (dnfLib.spaceMembers host);
  space = config.darkone.host.ai-space;
  workspaceDir = "${stateDir}/workspace";

  # ACP harness ids of the space's coding CLIs, the first one by default.
  codingAgents =
    lib.optional space.enableClaude "claude"
    ++ lib.optional space.enableCodex "codex"
    ++ lib.optional space.enableOpenCode "opencode";

  # Agent PATH: shell basics, the space's tools, the delegated coding CLIs.
  agentTools = [
    pkgs.git
    pkgs.curl
    pkgs.jq
    pkgs.ripgrep
  ]
  ++ space.packages
  ++ lib.optional space.enableClaude pkgs.claude-code-nix
  ++ lib.optional space.enableCodex pkgs.codex
  ++ lib.optional space.enableOpenCode pkgs.opencode;

  # OpenClaw rejects null or empty fields its schema types otherwise.
  compact = lib.filterAttrs (_: v: v != null && v != [ ] && v != { });

  # MCP secrets (`secretEnv`): one gateway env file for every server, hence a
  # name per server; uppercase, the only form `${VAR}` substitutes.
  mcpEnvName = server: var: lib.toUpper "MCP_${lib.replaceStrings [ "-" ] [ "_" ] server}_${var}";
  mcpSecrets = lib.concatLists (
    lib.mapAttrsToList (
      server: s:
      map (var: {
        env = mcpEnvName server var;
        key = "mcp/${server}/${var}";
      }) s.secretEnv
    ) space.mcp
  );
  mcpServers = lib.mapAttrs (
    server: s:
    compact (
      removeAttrs s [ "secretEnv" ]
      // {
        env = s.env // lib.genAttrs s.secretEnv (var: "\${${mcpEnvName server var}}");
      }
    )
  ) space.mcp;

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

  # Hypervisor's whisper.cpp server (`microvm/whisper.nix`).
  hypervisor = lib.findFirst (h: h.hostname == config.darkone.system.microvm.hypervisor) { } hosts;
  whisperUrl = "http://${hypervisor.ip}:${toString dnfConfig.network.ports.whisper}/inference";
  language = lib.escapeShellArg cfg.transcription.language;

  # Matrix voice notes are Opus: whisper.cpp reads WAV, ffmpeg converts.
  transcribe = pkgs.writeShellScript "openclaw-transcribe" (
    ''
      set -euo pipefail
      wav="$(${pkgs.coreutils}/bin/mktemp --suffix=.wav)"
      trap '${pkgs.coreutils}/bin/rm -f "$wav"' EXIT
      ${pkgs.ffmpeg-headless}/bin/ffmpeg -nostdin -loglevel error -y -i "$1" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"
    ''

    # Server down, restarting or busy past the delay: local model.
    + lib.optionalString (cfg.transcription.backend == "hypervisor") ''
      if text="$(${pkgs.curl}/bin/curl --silent --show-error --fail --connect-timeout 5 --max-time 90 \
        -F file=@"$wav" -F response_format=text -F language=${language} ${whisperUrl})"; then
        printf '%s\n' "$text"
        exit 0
      fi
      echo "openclaw-transcribe: hypervisor server failed, local fallback" >&2
    ''
    + ''
      ${pkgs.whisper-cpp}/bin/whisper-cli -m ${cfg.transcription.model} \
        -l ${language} -nt -np -f "$wav"
    ''
  );

  hypervisorTranscription = cfg.transcription.enable && cfg.transcription.backend == "hypervisor";

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
  ownerMxids = lib.optional (cfg.owner != null) "@${cfg.owner}:${network.domain}";
  tokenEnv = "OPENCLAW_MATRIX_TOKEN";

  # Runtime plugins, by store path. One list: the gateway config merges with
  # `recursiveUpdate`, which replaces lists.
  plugins =
    lib.optionalAttrs hasMatrix { matrix = pkgs.openclaw-runtime-plugin-matrix; }
    // lib.optionalAttrs cfg.lobster { lobster = pkgs.openclaw-runtime-plugin-lobster; }
    // lib.optionalAttrs (lib.elem "codex" (map runtimeOf models)) {
      codex = pkgs.openclaw-runtime-plugin-codex;
    };

  # Catalog, main model first.
  models = lib.unique ([ cfg.model ] ++ cfg.extraModels);
  providerOf = m: lib.head (lib.splitString "/" m);

  # Subscription runtime of a model, from its provider, when subscribed:
  # - `anthropic`: the logged-in `claude` CLI (Claude Pro/Max), which owns
  #   the token;
  # - `openai`: the `codex` plugin's app-server (ChatGPT Plus/Pro OAuth).
  # Else OpenClaw's own runtime, with the provider's API key.
  runtimeOf =
    m:
    let
      p = providerOf m;
    in
    if !lib.elem p cfg.subscriptions then
      null
    else if p == "anthropic" then
      "claude-cli"
    else
      "codex";

  # The `claude` CLI prefers `ANTHROPIC_API_KEY` to its login: never exported
  # beside the Claude subscription.
  droppedKeys = lib.optional (lib.elem "anthropic" cfg.subscriptions) "ANTHROPIC_API_KEY";
  keyVars = lib.subtractLists droppedKeys (
    lib.unique (
      cfg.apiKeys ++ lib.filter (k: k != null) (lib.mapAttrsToList (_: pr: pr.apiKey) cfg.providers)
    )
  );

  # Variables certain for these two; other providers name theirs freely.
  subscriptionKeys = {
    anthropic = "ANTHROPIC_API_KEY";
    openai = "OPENAI_API_KEY";
  };
  missingKeys = lib.filter (
    m:
    let
      p = providerOf m;
    in
    subscriptionKeys ? ${p} && runtimeOf m == null && !lib.elem subscriptionKeys.${p} keyVars
  ) models;
  keylessModels = lib.filter (
    m:
    let
      p = providerOf m;
    in
    !(subscriptionKeys ? ${p}) && !(cfg.providers ? ${p})
  ) models;

  # OpenAI-compatible providers absent from OpenClaw.
  providersConfig = lib.mapAttrs (
    _: pr:
    {
      inherit (pr) api baseUrl;
      models = map (id: {
        inherit id;
        name = id;
      }) pr.models;
    }
    // lib.optionalAttrs (pr.apiKey != null) {
      apiKey = {
        source = "env";
        provider = "default";
        id = pr.apiKey;
      };
    }
  ) cfg.providers;

  # Declared automations: upserted by declaration key (`nix-<name>`), the
  # `nix-*` ones no longer declared removed, any other left alone. Omitted
  # enablement keeps a job paused from the UI.
  declareAutomation =
    name: a:
    lib.escapeShellArgs (
      [
        "create"
        "--declaration-key"
        "nix-${name}"
        "--name"
        name
        "--description"
        "Declared in Nix (darkone.service.openclaw.automations)"
        "--agent"
        "main"
        "--message"
        a.message
      ]
      ++ (
        if lib.hasPrefix "every " a.schedule then
          [
            "--every"
            (lib.removePrefix "every " a.schedule)
          ]
        else
          [
            "--cron"
            a.schedule
          ]
      )
      ++ [ (if a.announce then "--announce" else "--no-deliver") ]
      ++ lib.optionals (a.model != null) [
        "--model"
        a.model
      ]
      ++ lib.optional (!a.enable) "--disabled"
    );
  syncAutomations = pkgs.writeShellScript "openclaw-automations" ''
    set -euo pipefail
    oc=${cli}/bin/openclaw
    jq=${pkgs.jq}/bin/jq

    # The gateway answers about a minute after its start.
    for _ in $(${pkgs.coreutils}/bin/seq 60); do
      $oc automations status > /dev/null 2>&1 && break
      ${pkgs.coreutils}/bin/sleep 5
    done
    ${lib.concatLines (
      lib.mapAttrsToList (
        name: a: "$oc automations ${declareAutomation name a} > /dev/null"
      ) cfg.automations
    )}
    list="$($oc automations list --all --json)"
    if [ "$(echo "$list" | $jq .hasMore)" = true ]; then
      echo "openclaw-automations: list truncated, stale nix-* jobs may remain" >&2
    fi
    echo "$list" | $jq -r --argjson keep ${
      lib.escapeShellArg (builtins.toJSON (map (n: "nix-${n}") (lib.attrNames cfg.automations)))
    } \
      '.jobs[] | select((.declarationKey // "") | startswith("nix-")) | select(.declarationKey as $k | $keep | index($k) | not) | .id' |
      while read -r id; do $oc automations rm "$id" > /dev/null; done
  '';

  # Mutable config: each leaf of the Nix config is imposed (rewritten) or
  # seeded (written when absent), longest prefix wins. Store paths are always
  # imposed: stale after an update or a GC.
  imposedRoots = [
    [ "gateway" ]
    [
      "channels"
      "matrix"
    ]
    [
      "commands"
      "ownerAllowFrom"
    ]
    [
      "plugins"
      "load"
    ]
    [
      "plugins"
      "entries"
    ]
    [
      "agents"
      "defaults"
      "workspace"
    ]
    [
      "agents"
      "defaults"
      "cwd"
    ]
    [
      "session"
      "dmScope"
    ]
    [
      "mcp"
      "servers"
    ]
    [
      "models"
      "providers"
    ]
    [
      "tools"
      "alsoAllow"
    ]
    [
      "tools"
      "media"
    ]
    [
      "skills"
      "load"
    ]
  ];
  seededRoots = [
    [
      "agents"
      "defaults"
      "model"
    ]
    [
      "agents"
      "defaults"
      "models"
    ]
    [
      "agents"
      "entries"
      "main"
      "identity"
    ]
    [
      "tools"
      "exec"
    ]
    [ "talk" ]
    [ "acp" ]
    [
      "skills"
      "entries"
    ]
    [
      "plugins"
      "entries"
      "acpx"
      "config"
      "permissionMode"
    ]
  ];

  # Lists are leaves: imposed whole.
  leafPaths =
    path: v:
    if builtins.isAttrs v && v != { } then
      lib.concatLists (lib.mapAttrsToList (n: leafPaths (path ++ [ n ])) v)
    else
      [ path ];
  longestRoot =
    roots: path:
    lib.foldl' (a: r: if lib.length r > lib.length a then r else a) [ ] (
      lib.filter (r: lib.take (lib.length r) path == r) roots
    );
  classify =
    path:
    let
      imposed = longestRoot imposedRoots path;
      seeded = longestRoot seededRoots path;
    in
    if imposed == [ ] && seeded == [ ] then
      null
    else if lib.length imposed > lib.length seeded then
      "imposed"
    else
      "seeded";

  nixConfig = config.services.openclaw-gateway.config;
  nixLeaves = leafPaths [ ] nixConfig;
  entry = path: {
    inherit path;
    value = lib.getAttrFromPath path nixConfig;
  };
  imposedEntries = map entry (lib.filter (p: classify p == "imposed") nixLeaves);
  seededEntries = map entry (lib.filter (p: classify p == "seeded") nixLeaves);
  unclassified = lib.filter (p: classify p == null) nixLeaves;
  seededStorePaths = lib.filter (
    p: classify p == "seeded" && builtins.hasContext (builtins.toJSON (lib.getAttrFromPath p nixConfig))
  ) nixLeaves;

  # Previous imposed leaves: deleted once Nix drops them (old owner scope,
  # removed plugin). Written only on a real change: the guard below fires on
  # its own writes, and OpenClaw may reformat the file.
  mergeSpec = pkgs.writeText "openclaw-config-merge.json" (
    builtins.toJSON {
      imposed = imposedEntries;
      seeded = seededEntries;
    }
  );
  mergeConfig = pkgs.writeShellScript "openclaw-config-merge" ''
    set -euo pipefail
    jq=${pkgs.jq}/bin/jq
    live=${configPath}
    prev=${stateDir}/.openclaw-imposed.json
    tmp="$live.nix-tmp"
    if [ -f "$live" ] && ! $jq empty "$live" 2>/dev/null; then
      echo "openclaw-config-merge: invalid $live, moved to $live.invalid" >&2
      ${pkgs.coreutils}/bin/mv -f "$live" "$live.invalid"
    fi
    [ -f "$live" ] || echo '{}' > "$live"
    [ -f "$prev" ] || echo '[]' > "$prev"
    $jq --slurpfile spec ${mergeSpec} --slurpfile prev "$prev" '
      $spec[0] as $s
      | reduce ($prev[0] - [ $s.imposed[].path ])[] as $p (.; delpaths([ $p ]))
      | reduce $s.seeded[] as $e (.;
          if (try getpath($e.path) catch 0) == null then setpath($e.path; $e.value) else . end)
      | reduce $s.imposed[] as $e (.; setpath($e.path; $e.value))
    ' "$live" > "$tmp"
    if $jq -e -n --slurpfile a "$live" --slurpfile b "$tmp" '$a == $b' > /dev/null; then
      ${pkgs.coreutils}/bin/rm -f "$tmp"
    else
      ${pkgs.coreutils}/bin/mv -f "$tmp" "$live"
    fi
    $jq '[ .imposed[].path ]' ${mergeSpec} > "$prev"
  '';

  matrixConfig = {

    # Owner: target of proactive messages (heartbeat `owner`, DM only).
    commands.ownerAllowFrom = map (m: "matrix:${m}") ownerMxids;
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

      # DMs with members only. Rooms ignored: non-members would read the
      # replies. Joins every invite (`autoJoinAllowlist` filters rooms, not
      # inviters), a DM being one.
      autoJoin = "always";
      dm = {
        enabled = true;
        policy = "allowlist";
        allowFrom = memberMxids;
      };
      groupPolicy = "disabled";
      execApprovals = {
        enabled = true;
        approvers = ownerMxids;
        target = "dm";
      };
    };
  };
in
{
  options = {
    darkone.service.openclaw = {
      enable = lib.mkEnableOption "Enable the OpenClaw assistant of an AI space";

      owner = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = if lib.length members == 1 then lib.head members else null;
        defaultText = lib.literalMD "the only member, if any";
        example = "alice";
        description = ''
          Member owning the space: its subscription logs the agent in
          (`model`), it receives approval requests and proactive messages.
          Required with several members (`users` order is not kept).
        '';
      };

      cliUsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.optional (cfg.owner != null && !config.security.sudo.execWheelOnly) cfg.owner;
        defaultText = lib.literalMD "the owner, unless sudo is restricted to `wheel`";
        example = [
          "alice"
          "bob"
        ];
        description = ''
          Members running the host CLI (`openclaw`) as the service user, by a
          sudo rule: TUI, provider logins, admin. Its `!` shell commands run as
          `openclaw` too, the space's tokens within reach.
        '';
      };

      model = lib.mkOption {
        type = lib.types.str;
        default = "anthropic/claude-sonnet-5-5";
        example = "openai/gpt-6-astra";
        description = ''
          Main model, `<provider>/<model>`: through the owner's subscription
          when its provider is in `subscriptions`, else an API key (`apiKeys`).
        '';
      };

      extraModels = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "openai/gpt-6-astra"
          "openrouter/moonshotai/kimi-k3"
        ];
        description = "Other models of the catalog, picked in the chat with `/model`; same rules as `model`.";
      };

      subscriptions = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "anthropic"
            "openai"
          ]
        );
        default = [
          "anthropic"
          "openai"
        ];
        example = [ "openai" ];
        description = ''
          Subscriptions of the owner, used first by the models of their provider:
          - `anthropic`: Claude Pro/Max through the `claude` CLI (needs
            `darkone.host.ai-space.enableClaude`);
          - `openai`: ChatGPT Plus/Pro through the `codex` plugin.

          Other providers, or one left out, go through an API key (`apiKeys`).
        '';
      };

      apiKeys = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[A-Z][A-Z0-9_]*");
        default = [ ];
        example = [ "OPENROUTER_API_KEY" ];
        description = ''
          Provider API keys, by variable: read from the space's sops file
          (`openclaw/<VAR>`, `just space-sops <host>`) into the gateway
          environment. `ANTHROPIC_API_KEY` is dropped beside the `anthropic`
          subscription, which it would override.
        '';
      };

      providers = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              baseUrl = lib.mkOption {
                type = lib.types.str;
                example = "https://inference-api.nousresearch.com/v1";
                description = "API endpoint.";
              };
              api = lib.mkOption {
                type = lib.types.str;
                default = "openai-completions";
                description = "API flavour (OpenClaw `models.providers.<id>.api`).";
              };
              apiKey = lib.mkOption {
                type = lib.types.nullOr (lib.types.strMatching "[A-Z][A-Z0-9_]*");
                default = null;
                example = "NOUS_API_KEY";
                description = "Key variable, read like `apiKeys`.";
              };
              models = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                example = [ "Hermes-4-405B" ];
                description = "Model ids, referenced as `<provider>/<id>`.";
              };
            };
          }
        );
        default = { };
        description = "Providers absent from OpenClaw (Nous Portal...), OpenAI-compatible by default.";
      };

      mutableConfig = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Config writable from the UI and `openclaw config set`, the owner being
          operator admin. Nix keys merged at each start:
          - imposed, rewritten (also on any change of the file): gateway and
            access, Matrix channel, plugins, MCP servers, store paths;
          - seeded, written when absent, then the UI rules: `model`, `exec`,
            `identity`, talk, ACP, skill switches.
        '';
      };

      exec = lib.mkOption {
        type = lib.types.enum [
          "full"
          "auto"
          "ask"
          "allowlist"
          "deny"
        ];
        default = "full";
        example = "ask";
        description = ''
          Command policy of the agent (OpenClaw `tools.exec.mode`):
          - `full`: any command, unapproved (OpenClaw default);
          - `ask`: allowlisted commands run, any other asks the owner;
          - `auto`: a model reviews misses, the owner decides when it is unsure;
          - `allowlist`, `deny`: allowlisted commands only, none.

          Allowlist: `openclaw approvals allowlist add --agent main <path>`. With
          the `claude-cli` runtime, pipes, redirections and substitutions are
          refused before any prompt outside `full`.
        '';
      };

      identity = {
        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "Jarvis";
          description = "Name of the assistant, shown in the UI.";
        };
        emoji = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "🦉";
          description = "Emoji of the assistant, shown in the UI.";
        };
        avatar = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Avatar image (URL or workspace-relative path).";
        };
      };

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
          Git repositories cloned once into `<projectsDir>/<name>`
          (`darkone.host.ai-space.projectsDir`), never pulled. SSH remotes use
          the key of `openclaw` (`/var/lib/openclaw/.ssh`, created by hand); the
          server key is accepted on first clone.
        '';
      };

      talk = {
        enable = lib.mkEnableOption "Talk: live voice conversation in the browser (OpenAI GPT-Live)";
        model = lib.mkOption {
          type = lib.types.str;
          default = "gpt-live-1-codex";
          description = ''
            Realtime model. `gpt-live-1-codex`: the owner's ChatGPT login
            (`openclaw models auth login --provider openai`), else a Platform
            key (`OPENAI_API_KEY`); `gpt-live-1`, `gpt-realtime-2.1` (camera):
            Platform key only. Pinned: unset, a Platform key wins over ChatGPT.
          '';
        };
        voice = lib.mkOption {
          type = lib.types.str;
          default = "cove";
          example = "sol";
          description = "Voice of the model's route (`gpt-live-1-codex`: `cove`, `arbor`, `breeze`, `ember`, `juniper`, `maple`, `sol`, `spruce`, `vale`).";
        };
        instructions = lib.mkOption {
          type = lib.types.nullOr lib.types.lines;
          default = null;
          example = "Réponds en français, en phrases courtes.";
          description = "Instructions appended to OpenClaw's realtime prompt.";
        };
      };

      lobster = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Lobster workflows: pipelines run by the gateway, with approval steps
          and resume, plus `llm-task` (structured LLM step). Workflow files go
          through `workspace` (`"workflows/<name>.lobster"`).
        '';
      };

      automations = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              schedule = lib.mkOption {
                type = lib.types.str;
                example = "0 7 * * 1-5";
                description = "Cron expression (5 or 6 fields), or `every <duration>` (`every 2h`).";
              };
              message = lib.mkOption {
                type = lib.types.lines;
                example = "Résume mes mails non lus et mon agenda du jour.";
                description = "Prompt of the agent's run.";
              };
              announce = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Send the final reply to the chat (owner's last channel).";
              };
              model = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Model override, `<provider>/<model>` or alias.";
              };
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "False: kept disabled; once so, re-enabled from the UI only (`openclaw automations enable <id>`).";
              };
            };
          }
        );
        default = { };
        example = lib.literalExpression ''{ briefing = { schedule = "0 7 * * 1-5"; message = "Résume mon agenda du jour."; }; }'';
        description = ''
          Scheduled agent runs declared in Nix, kept in sync at each start
          (`nix-<name>`, edits from the UI overwritten); those of the agent and
          the UI are left alone.
        '';
      };

      transcription = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Transcribe voice notes (whisper.cpp, CPU).";
        };
        backend = lib.mkOption {
          type = lib.types.enum [
            "hypervisor"
            "local"
          ];
          default = if config.darkone.system.microvm.hypervisor != null then "hypervisor" else "local";
          defaultText = lib.literalMD "`hypervisor` on a microVM guest, else `local`";
          description = ''
            Where voice notes are transcribed:
            - `hypervisor`: the hypervisor's whisper.cpp server (bigger model,
              more cores), `model` as fallback;
            - `local`: on this host, with `model`.
          '';
        };
        model = lib.mkOption {
          type = lib.types.path;
          default = pkgs.fetchurl {
            url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin";
            sha256 = "0ywqxbziyp2bv72riyjpw4brk9v46d4cfbjfwqvvjrrq0srakqqv";
          };
          defaultText = lib.literalMD "whisper.cpp ggml `small` model (466 MB)";
          description = "whisper.cpp ggml model of local transcription (`local` backend, fallback).";
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
        persist.dirs = [
          stateDir
          space.projectsDir
        ];
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
        {
          assertion = members == [ ] || lib.elem cfg.owner members;
          message = "${host.hostname}: set `darkone.service.openclaw.owner` to one of its members (${lib.concatStringsSep ", " members}).";
        }
        {
          assertion = lib.all (u: lib.elem u members) cfg.cliUsers;
          message = "${host.hostname}: `darkone.service.openclaw.cliUsers` must be members (${lib.concatStringsSep ", " members}).";
        }
        {
          assertion = cfg.cliUsers == [ ] || !config.security.sudo.execWheelOnly;
          message = "${host.hostname}: `darkone.service.openclaw.cliUsers` go through sudo, restricted to `wheel` here (`security.sudo.execWheelOnly`).";
        }
        {
          assertion = !lib.elem "anthropic" cfg.subscriptions || space.enableClaude;
          message = "${host.hostname}: the `anthropic` subscription runs through the `claude` CLI: set `darkone.host.ai-space.enableClaude`, or drop it from `darkone.service.openclaw.subscriptions`.";
        }
        {
          assertion = missingKeys == [ ];
          message = "${host.hostname}: openclaw models outside `subscriptions` without their key in `apiKeys`: ${lib.concatStringsSep ", " missingKeys}.";
        }
        {
          assertion = !cfg.mutableConfig || unclassified == [ ];
          message = "${host.hostname}: openclaw keys neither imposed nor seeded (`imposedRoots`, `seededRoots`): ${
            lib.concatMapStringsSep ", " (lib.concatStringsSep ".") unclassified
          }.";
        }
        {
          assertion = !cfg.mutableConfig || seededStorePaths == [ ];
          message = "${host.hostname}: openclaw seeded keys holding a store path, to impose: ${
            lib.concatMapStringsSep ", " (lib.concatStringsSep ".") seededStorePaths
          }.";
        }
        {
          assertion = !hypervisorTranscription || config.darkone.system.microvm.hypervisor != null;
          message = "${host.hostname}: `darkone.service.openclaw.transcription.backend = \"hypervisor\"` needs a microVM guest (`microvm-guest:<hypervisor>`).";
        }
      ];
      warnings =
        lib.optional (memberEmails == [ ]) (
          "${host.hostname}: openclaw without members (`users` of the host): nobody passes the SSO."
        )
        ++ lib.optional (lib.elem "ANTHROPIC_API_KEY" cfg.apiKeys && droppedKeys != [ ]) (
          "${host.hostname}: openclaw `ANTHROPIC_API_KEY` not exported: the `claude` CLI would prefer it to the `anthropic` subscription."
        )
        ++
          lib.optional
            (cfg.talk.enable && cfg.talk.model != "gpt-live-1-codex" && !lib.elem "OPENAI_API_KEY" keyVars)
            (
              "${host.hostname}: openclaw Talk model `${cfg.talk.model}` needs a Platform key: add `OPENAI_API_KEY` to `apiKeys`."
            )
        ++ lib.optional (keylessModels != [ ] && cfg.apiKeys == [ ]) (
          "${host.hostname}: openclaw models through an API key, none in `apiKeys`: ${lib.concatStringsSep ", " keylessModels}."
        );

      darkone.system.microvm.guest.whisper = hypervisorTranscription;

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

        # Any arguments: the CLI is the whole service account anyway.
        security.sudo.extraRules = lib.optional (cfg.cliUsers != [ ]) {
          users = cfg.cliUsers;
          runAs = "openclaw";
          commands = [
            {
              command = "${cliRun}";
              options = [ "NOPASSWD" ];
            }
          ];
        };

        # Agent commands run unapproved in this unit: second wall inside the
        # guest, writes to the state and the projects only. No `MemoryDenyWriteExecute` (V8 JIT)
        # nor syscall filter (agent tools vary). Checked: claude, codex, nix,
        # git, whisper.
        systemd.services.openclaw-gateway.serviceConfig = {
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [
            stateDir
            space.projectsDir
          ];
          ProtectProc = "invisible";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictSUIDSGID = true;
          RestrictRealtime = true;
          LockPersonality = true;
          RemoveIPC = true;
          CapabilityBoundingSet = "";
          SystemCallArchitectures = "native";
          UMask = "0077";
        };
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

              # Approvals: the owner's sessions, not every member's device.
              # Admin with a mutable config: settings of the UI.
              identityScopes = lib.optionalAttrs (cfg.owner != null) {
                ${users.${cfg.owner}.email} = [
                  "operator.approvals"
                ]
                ++ lib.optional cfg.mutableConfig "operator.admin";
              };
              trustedProxy = {
                userHeader = "x-auth-request-email";
                allowUsers = memberEmails;

                # The SSO is the enrollment boundary: no admin nor approvals
                # scope here (approvals: `identityScopes`, owner only).
                deviceAutoApprove = {
                  enabled = true;
                  scopes = [
                    "operator.read"
                    "operator.write"
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
          # `cli`: coding workers report back with `openclaw message send`.
          servicePath = agentTools ++ [ cli ];
          execStartPre = lib.optional (cfg.workspace != { }) "${installWorkspace}";

          # Pinned: the default follows `$HOME`, not the state dir.
          config = lib.mkMerge [
            {
              agents.defaults = {
                workspace = workspaceDir;

                # Commands and deliverables; bootstrap files and memory stay
                # in the workspace. Outside the state: coding workers refuse it.
                cwd = space.projectsDir;
                model.primary = cfg.model;
                models = lib.genAttrs models (
                  m: lib.optionalAttrs (runtimeOf m != null) { agentRuntime.id = runtimeOf m; }
                );
              };
              tools.exec.mode = cfg.exec;
            }
            (lib.mkIf (cfg.providers != { }) { models.providers = providersConfig; })
            (lib.mkIf cfg.lobster {
              plugins.entries.llm-task.enabled = true;
              tools.alsoAllow = [
                "lobster"
                "llm-task"
              ];
            })

            # Claude and Codex adapters ship with acpx; OpenCode by store path,
            # not `npx` at first use.
            (lib.mkIf (codingAgents != [ ]) {
              skills.entries.coding-agent.enabled = true;
              acp = {
                enabled = true;
                backend = "acpx";
                defaultAgent = lib.head codingAgents;
                allowedAgents = codingAgents;
              };
              plugins.entries.acpx = {
                enabled = true;
                config = {
                  permissionMode = if cfg.exec == "full" then "approve-all" else "approve-reads";
                }
                // lib.optionalAttrs space.enableOpenCode {
                  agents.opencode = {
                    command = "${pkgs.opencode}/bin/opencode";
                    args = [ "acp" ];
                  };
                };
              };
            })

            # WebRTC between browser and OpenAI, SDP through the gateway; the
            # bundled `openai` plugin must load (never `plugins.allow`).
            (lib.mkIf cfg.talk.enable {
              talk.realtime = {
                provider = "openai";
                transport = "webrtc";
                brain = "agent-consult";
                providers.openai = {
                  inherit (cfg.talk) model;
                  speakerVoice = cfg.talk.voice;
                };
              }
              // lib.optionalAttrs (cfg.talk.instructions != null) { inherit (cfg.talk) instructions; };
            })

            # What `openclaw agents set-identity` would write: the config is
            # read-only, the identity is declared here.
            (lib.mkIf (compact cfg.identity != { }) { agents.entries.main.identity = compact cfg.identity; })
            (lib.mkIf (space.mcp != { }) { mcp.servers = mcpServers; })
            (lib.mkIf (space.skills != { }) { skills.load.extraDirs = [ "${skillsDir}" ]; })
            (lib.mkIf cfg.transcription.enable transcriptionConfig)
          ];
        };

        # After the gateway, whose restart reruns it; also runs with no
        # declaration, to remove the `nix-*` jobs left behind.
        systemd.services.openclaw-automations = {
          description = "Sync the automations of the OpenClaw assistant";
          wantedBy = [ "openclaw-gateway.service" ];
          after = [ "openclaw-gateway.service" ];
          partOf = [ "openclaw-gateway.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "openclaw";
            Group = "openclaw";
            ExecStart = "${syncAutomations}";
          };
        };

        # Best effort: a remote not reachable yet (key, network) is logged and
        # retried at the next boot, it never fails the deploy.
        systemd.services.openclaw-projects = lib.mkIf (cfg.projects != { }) {
          description = "Clone the projects of the AI space";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];

          # Non-interactive: an unknown server key would fail every first clone.
          environment.GIT_SSH_COMMAND = "${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=accept-new";
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
                dir = lib.escapeShellArg "${space.projectsDir}/${name}";
              in

              # Group-writable objects and refs: members work in it too.
              ''
                [ -d ${dir}/.git ] || ${pkgs.git}/bin/git clone -c core.sharedRepository=group ${lib.escapeShellArg url} ${dir} \
                  || echo "openclaw-projects: ${name} not cloned (${url})" >&2
              ''
            ) cfg.projects
          );
        };
      }
    ))

    #------------------------------------------------------------------------
    # Mutable config
    #------------------------------------------------------------------------

    (lib.optionalAttrs (options ? services.openclaw-gateway) (
      lib.mkIf (cfg.enable && cfg.mutableConfig) {

        # Unset, the package wrapper sets `OPENCLAW_NIX_MODE=1`: read-only UI.
        # Merged over the module's variables: the state file wins over `/etc`.
        services.openclaw-gateway = {
          environment = {
            OPENCLAW_NIX_MODE = "0";
            OPENCLAW_CONFIG_PATH = configPath;
            CLAWDBOT_CONFIG_PATH = configPath;
          };
          execStartPre = [ "${mergeConfig}" ];
        };

        # The agent runs as `openclaw` too: imposed keys come back as soon as
        # the file changes, not at the next start only.
        systemd.paths.openclaw-config-guard = {
          wantedBy = [ "multi-user.target" ];
          pathConfig.PathChanged = configPath;
        };
        systemd.services.openclaw-config-guard = {
          description = "Re-impose the Nix keys of the OpenClaw config";
          serviceConfig = {
            Type = "oneshot";
            User = "openclaw";
            Group = "openclaw";
            ExecStart = "${mergeConfig}";
            UMask = "0077";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ stateDir ];
          };
        };
      }
    ))

    #------------------------------------------------------------------------
    # Secrets, plugins, Matrix channel
    #------------------------------------------------------------------------

    (lib.optionalAttrs (options ? services.openclaw-gateway) (
      lib.mkIf cfg.enable {

        # sops-nix files are symlinks, which OpenClaw's file provider rejects:
        # secrets reach it as environment variables. The password serves
        # internal callers only (host CLI), Caddy still goes `trusted-proxy`.
        sops.secrets = {
          openclaw-gateway-password = { };
        }
        // lib.optionalAttrs hasMatrix { openclaw-matrix-token = { }; }
        // lib.genAttrs (map (var: "openclaw/${var}") keyVars) (_: { });
        sops.templates."openclaw-gateway.env" = {
          content = ''
            OPENCLAW_GATEWAY_PASSWORD=${config.sops.placeholder.openclaw-gateway-password}
          ''
          + lib.optionalString hasMatrix ''
            ${tokenEnv}=${config.sops.placeholder.openclaw-matrix-token}
          ''
          + lib.concatMapStrings (s: "${s.env}=${config.sops.placeholder.${s.key}}\n") mcpSecrets
          + lib.concatMapStrings (var: "${var}=${config.sops.placeholder."openclaw/${var}"}\n") keyVars;
          owner = "openclaw";
        };

        services.openclaw-gateway = {
          environmentFiles = [ envFile ];

          # Plugins by store path: the persisted registry would shadow them.
          environment.OPENCLAW_DISABLE_PERSISTED_PLUGIN_REGISTRY = "1";
          config = lib.mkMerge [
            (lib.mkIf (plugins != { }) {
              plugins = {
                load.paths = map toString (lib.attrValues plugins);
                entries = lib.mapAttrs (_: _: { enabled = true; }) plugins;
              };
            })
            (lib.mkIf hasMatrix matrixConfig)

            # Several members: one DM session each, else the agent's main session
            # mixes their conversations. Context split only, not isolation.
            (lib.mkIf (hasMatrix && lib.length members > 1) { session.dmScope = "per-channel-peer"; })
          ];
        };
      }
    ))
  ];
}
