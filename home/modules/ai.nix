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
# governance hook on Bash calls.
# :::

{
  lib,
  pkgs,
  config,
  osConfig,
  ...
}:
let
  cfg = config.darkone.home.ai;
  graphic = osConfig.darkone.graphic.gnome.enable;

  # True when this host runs the DNF local AI service (ollama).
  hasLocalAI = osConfig.darkone.service.ai.enable;

  ollamaModel = "llama3.2:3b";
  ollamaBase = "ollama/${ollamaModel}";

  # Aider model: prefer Claude if enabled, fall back to local ollama.
  aiderModel =
    if cfg.enableClaude then
      "anthropic/claude-sonnet-4-6"
    else if hasLocalAI then
      ollamaBase
    else
      "anthropic/claude-sonnet-4-6";
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

      # OpenCode desktop UI (requires a graphical environment).
      (lib.mkIf (cfg.enableOpenCode && graphic) opencode-desktop)
    ];

    #==========================================================================
    # CLAUDE CODE
    #==========================================================================

    programs.claude-code = lib.mkIf cfg.enableClaude {
      enable = true;
      settings = {

        hooks.PreToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                type = "command";

                # RTK intercepts each Bash call for logging/governance.
                command = "rtk hook claude";
              }
            ];
          }
        ];

        includeCoAuthoredBy = false;
        theme = "dark";

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

            # Nix — read/evaluation only
            "Bash(nix eval:*)"
            "Bash(nix flake check:*)"
            "Bash(nix repl:*)"

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
            "WebFetch"
            "WebSearch"
          ];

          ask = [
            
            # Claude Code native tools — create/overwrite files.
            "Write"

            # Git — state-modifying
            "Bash(git add:*)"
            "Bash(git checkout:*)"
            "Bash(git commit:*)"
            "Bash(git push:*)"
            "Bash(git rebase:*)"
            "Bash(git reset:*)"

            # Nix — builds and installs write to the store
            "Bash(nix build:*)"
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
    };

    #==========================================================================
    # OPENCODE
    #==========================================================================

    programs.opencode = lib.mkIf cfg.enableOpenCode {
      enable = true;

      # MCP expands the agent's toolset (filesystem, GitHub, search, etc.)
      enableMcpIntegration = true;

      settings = {

        # Prefer local ollama when available to avoid cloud API costs.
        model = if (hasLocalAI && cfg.preferLocal) then ollamaBase else "opencode/big-pickle";
        autoshare = false;

        # NixOS manages upgrades declaratively; runtime auto-update breaks reproducibility.
        autoupdate = false;

        # MCP servers — require Node.js (npx) at runtime.
        mcpServers = {
          filesystem = {
            command = "npx";
            args = [
              "-y"
              "@modelcontextprotocol/server-filesystem"
              config.home.homeDirectory
            ];
          };
          fetch = {
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-fetch" ];
          };
        };
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
