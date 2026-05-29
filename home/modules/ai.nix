# AI coding tools and supporting utilities.
#
# :::note[Flags]
# - `darkone.home.ai.enable` master switch installs utility packages
#   (aichat, llm, fabric-ai, gh, lazygit, direnv, code-quality tools, etc.)
#   and enables the per-agent flag system below.
# - `darkone.home.ai.enable{Claude,OpenCode,Codex,Aider,Goose}` each
#   installs and configures a specific AI coding agent.
# - `darkone.home.ai.preferLocal` when combined with a local `darkone.service.ai`
#   ollama host, agents default to the local model instead of cloud APIs.
# :::
#
# :::tip[Per-host wiring]
# This module reads `osConfig.darkone.service.ai.enable` to detect a
# local ollama host.  On such hosts, `gollama`, the `ollama` CLI, and
# local-model defaults for Aider / OpenCode are activated automatically.
#
# `programs.gh` is enabled with the `github-copilot-cli` extension.
# OpenCode gets two MCP servers (filesystem, fetch) via `npx -y`.
# Claude Code enforces an allow/ask/deny permission matrix and an RTK
# governance hook on Bash calls. Its `settings.json` is NOT pinned as a
# read-only store symlink: the socle is merged into a WRITABLE
# `~/.claude/settings.json` on every switch, so plugins/add-ons
# (claude-mem, graphify, ...) can be installed and managed by hand on top.
# :::

{
  lib,
  pkgs,
  config,
  osConfig,
  inputs,
  ...
}:
let
  cfg = config.darkone.home.ai;
  graphic = osConfig.darkone.graphic.gnome.enable;

  # True when this host runs the DNF local AI service (ollama).
  hasLocalAI = osConfig.darkone.service.ai.enable;

  ollamaModel = builtins.head osConfig.services.ollama.loadModels;
  ollamaBase = "ollama/${ollamaModel}";

  # Aider model: prefer Claude if enabled, fall back to local ollama.
  aiderModel =
    if cfg.enableClaude then
      "anthropic/claude-sonnet-4-6"
    else if hasLocalAI then
      ollamaBase
    else
      "anthropic/claude-sonnet-4-6";

  # Claude Code governance socle (permission matrix + RTK PreToolUse hook).
  # Kept as Nix data, rendered to an immutable store JSON, then merged into a
  # writable settings.json by `claudeSettingsMerge` below. We keep settings.json
  # writable on purpose: read-only store symlinks would block manual plugin
  # installs (`npx claude-mem install` & co. fail with EROFS).
  claudeSettings = {
    "$schema" = "https://json.schemastore.org/claude-code-settings.json";

    hooks.PreToolUse = [
      {
        matcher = "Bash";

        # RTK intercepts each Bash call for logging/governance.
        hooks = [
          {
            type = "command";
            command = "rtk hook claude";
          }
        ];
      }
    ];

    includeCoAuthoredBy = false;
    theme = "dark";

    statusLine = {
      type = "command";
      command = "npx -y ccstatusline@latest";
      padding = 0;
      refreshInterval = 10;
    };

    permissions = {
      defaultMode = "acceptEdits";

      # Prevent users from bypassing the permission system at runtime.
      disableBypassPermissionsMode = "disable";

      # Policy: allow = read-only/idempotent, ask = writes/destructive.
      allow = [

        # File inspection
        "Bash(awk:*)"
        "Bash(bat:*)"
        "Bash(cat:*)"
        "Bash(comm:*)"
        "Bash(diff:*)"
        "Bash(echo:*)"
        "Bash(fd:*)"
        "Bash(file:*)"
        "Bash(find:*)"
        "Bash(grep:*)"
        "Bash(head:*)"
        "Bash(jq:*)"
        "Bash(ls:*)"
        "Bash(rg:*)"
        "Bash(sort:*)"
        "Bash(stat:*)"
        "Bash(tail:*)"
        "Bash(tokei:*)"
        "Bash(tree:*)"
        "Bash(uniq:*)"
        "Bash(wc:*)"
        "Bash(xargs:*)"

        # Code analysis
        "Bash(ast-grep:*)"
        "Bash(deadnix:*)"
        "Bash(rust-analyzer:*)"
        "Bash(shellcheck:*)"

        # Git — read only
        "Bash(git blame:*)"
        "Bash(git diff:*)"
        "Bash(git log:*)"
        "Bash(git show:*)"
        "Bash(git status:*)"
        "Bash(git add:*)"
        "Bash(git checkout:*)"

        # Nix — read/evaluation only
        "Bash(nix eval:*)"
        "Bash(nix flake check:*)"
        "Bash(nix repl:*)"
        "Bash(nix build:*)"

        # Cargo — build/test/format are idempotent
        "Bash(cargo build:*)"
        "Bash(cargo check:*)"
        "Bash(cargo clippy:*)"
        "Bash(cargo fmt:*)"
        "Bash(cargo test:*)"

        # Formatters — idempotent, no side effects
        "Bash(nixfmt:*)"
        "Bash(shfmt:*)"
        "Bash(statix:*)"
        "Bash(treefmt:*)"

        # Network — read/download only
        "Bash(curl:*)"
        "Bash(wget:*)"

        # Task runners and AI hooks
        "Bash(just:*)"
        "Bash(QUIET=1 just:*)"
        "Bash(rtk:*)"

        # Claude Code native tools
        "Edit"
        "Read"
        "Read(/nix/store/**)"
        "WebFetch"
        "WebSearch"
        "Write"
      ];

      ask = [

        # Git — state-modifying
        "Bash(git commit:*)"
        "Bash(git push:*)"
        "Bash(git rebase:*)"
        "Bash(git reset:*)"

        # Nix — builds and installs write to the store
        "Bash(nix shell:*)"
        "Bash(nix:*)"

        # Cargo — publish and install have external effects
        "Bash(cargo install:*)"
        "Bash(cargo publish:*)"

        # Privileged / external access
        "Bash(gh:*)"
        "Bash(rm:*)"
        "Bash(ssh:*)"
        "Bash(sudo:*)"
        "Bash(systemctl:*)"
      ];

      deny = [

        # Never expose secrets to the AI agent.
        "Read(*/secrets/**)"
      ];
    };
  };

  # Immutable JSON rendering of the socle in the nix store.
  claudeSettingsFile = (pkgs.formats.json { }).generate "claude-code-settings.json" claudeSettings;

  # Activation helper: keep ~/.claude/settings.json WRITABLE while reapplying
  # the Nix-owned socle on every switch. jq deep-merge with the socle as the
  # winning operand — nix keys (permissions, RTK hook) always win, but manual
  # additions (`enabledPlugins`, marketplaces, extra hooks) are preserved.
  claudeSettingsMerge = pkgs.writeShellScript "claude-settings-merge" ''
    set -euo pipefail

    settings="$HOME/.claude/settings.json"

    ${pkgs.coreutils}/bin/mkdir -p "$HOME/.claude"

    if [ -f "$settings" ] && [ ! -L "$settings" ]; then

      # Writable file already present: merge, socle wins on conflicts.
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$settings" ${claudeSettingsFile} > "$settings.hm-tmp"
      ${pkgs.coreutils}/bin/mv -f "$settings.hm-tmp" "$settings"
    else

      # First seed, or replacing a leftover read-only store symlink.
      ${pkgs.coreutils}/bin/rm -f "$settings"
      ${pkgs.coreutils}/bin/install -m644 ${claudeSettingsFile} "$settings"
    fi
  '';
in
{
  options = {
    darkone.home.ai.enable = lib.mkEnableOption "Enable AI tools and supporting utilities";
    darkone.home.ai.enableClaude = lib.mkEnableOption "Claude Code CLI";
    darkone.home.ai.enableOpenCode = lib.mkEnableOption "OpenCode terminal AI agent";
    darkone.home.ai.enableCodex = lib.mkEnableOption "OpenAI Codex CLI";
    darkone.home.ai.enableAider = lib.mkEnableOption "Aider AI pair programming";
    darkone.home.ai.enableGoose = lib.mkEnableOption "Goose AI coding agent (Block Inc.)";
    darkone.home.ai.preferLocal = lib.mkEnableOption "Prefer local models than cloud ones";
  };

  config = lib.mkIf cfg.enable {

    #==========================================================================
    # PACKAGES
    #==========================================================================

    home.packages = with pkgs; [

      # Rust dev stack — needed to build/audit AI tools and system code.
      cargo
      cargo-audit
      clippy
      gcc
      pkg-config
      rust-analyzer
      rustc
      rustfmt

      # RTK: pre-tool hook bridge for Claude Code.
      rtk

      # Versatile multi-backend CLI AI client (works with Claude, Ollama, etc.)
      aichat

      # Pipe-oriented LLM CLI with plugin system and shell composability.
      llm

      # Pattern-based AI prompting framework with hundreds of built-in recipes.
      fabric-ai

      # Code-quality and file-inspection tools — must stay in sync with the Claude Code allow list.
      ast-grep # AST-aware search/replace
      bat # syntax-highlighted cat
      deadnix # remove unused Nix bindings
      fd # user-friendly find
      ripgrep # fast grep (rg)
      shellcheck
      shfmt
      statix # Nix linter
      tokei # code statistics

      # Git workflow — review AI-generated diffs before committing.
      delta # syntax-highlighted pager for git diff/show
      lazygit # TUI client for staged review

      # Dev workflow — environment isolation and reactive loops.
      direnv # per-project .envrc; isolates API keys and project-scoped env vars
      fzf # fuzzy finder for interactive agentic navigation
      watchexec # file-event trigger for automated dev loops

      # GitHub CLI — required for agentic PR/issue workflows.
      gh

      # Ollama CLI + model manager, only useful when ollama runs locally.
      (lib.mkIf hasLocalAI gollama)
      (lib.mkIf hasLocalAI ollama)

      # Per-agent packages.
      (lib.mkIf cfg.enableCodex codex)
      (lib.mkIf cfg.enableAider aider-chat)
      (lib.mkIf cfg.enableGoose goose-cli)

      # Claude Code — self-contained native binary (no runtime deps).
      # Package from sadjow/claude-code-nix flake, updated hourly.
      (lib.mkIf cfg.enableClaude inputs.claude-code.packages.${pkgs.system}.default)

      # OpenCode desktop UI (requires a graphical environment).
      (lib.mkIf (cfg.enableOpenCode && graphic) opencode-desktop)
    ];

    #==========================================================================
    # CLAUDE CODE
    #==========================================================================

    # Seed/merge the governance socle into a writable ~/.claude/settings.json.
    # Runs after the HM writeBoundary so $HOME is fully provisioned.
    home.activation.claudeWritableSettings = lib.mkIf cfg.enableClaude (
      lib.hm.dag.entryAfter [ "writeBoundary" ] "run ${claudeSettingsMerge}"
    );

    #==========================================================================
    # OPENCODE
    #==========================================================================

    programs.opencode = lib.mkIf cfg.enableOpenCode {
      enable = true;

      settings = {

        # Prefer local ollama when available to avoid cloud API costs.
        model = lib.mkIf (hasLocalAI && cfg.preferLocal) ollamaBase;
        autoshare = false;

        # NixOS manages upgrades declaratively; runtime auto-update breaks reproducibility.
        autoupdate = false;

        # MCP servers — require Node.js (npx) at runtime.
        # Schema: type + command array required for local servers.
        # TODO: check security + fetch -> not working
        # mcp = {
        #   # filesystem = {
        #   #   type = "local";
        #   #   command = [
        #   #     "npx"
        #   #     "-y"
        #   #     "@modelcontextprotocol/server-filesystem"
        #   #     config.home.homeDirectory
        #   #   ];
        #   # };
        #   fetch = {
        #     type = "local";
        #     command = [
        #       "npx"
        #       "-y"
        #       "@modelcontextprotocol/server-fetch"
        #     ];
        #   };
        # };
      };
    };

    #==========================================================================
    # GITHUB CLI EXTENSIONS
    #==========================================================================

    programs.gh = {
      enable = true;
      extensions = [ pkgs.github-copilot-cli ];
    };

    #==========================================================================
    # AIDER
    #==========================================================================

    home.file.".aider.conf.yml" = lib.mkIf cfg.enableAider {
      text = ''
        # Aider AI pair programming configuration.
        # https://aider.chat/docs/config/aider_conf.html
        model: ${aiderModel}
        dark-mode: true

        # Never auto-commit — human reviews every change.
        auto-commits: false
        gitignore: true

        # Stream output for interactive sessions.
        stream: true
      '';
    };
  };
}
