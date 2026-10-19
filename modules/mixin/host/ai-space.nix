# AI space: headless host running the agents of one space (owner + members).
#
# Server base with secrets isolated from the fleet: agents read untrusted
# input (mail, web, chat), so the host only decrypts its own
# `usr/secrets/hosts/<hostname>.yaml`. Usually a microVM guest
# (`features: ["microvm-guest:<hypervisor>"]`), bare metal works too.
#
# Agent tooling, declared once per space (`usr/machines/<host>/configuration.nix`)
# and shared by the OpenClaw assistant and every member's Claude Code / Codex
# (`darkone.home.aiSpace`, on by default in the `space-member` home):
#
# - `mcp`: MCP servers, local (`command`) or remote (`url`);
# - `skills`: `SKILL.md` content, a file or a skill directory, by name;
# - `enableClaude`, `enableCodex`: CLIs for members and for OpenClaw delegation;
# - `packages`: tools on the agents' PATH and in members' homes.
#
# ```nix
# darkone.host.ai-space = {
#   mcp.fetch = { command = "uvx"; args = [ "mcp-server-fetch" ]; };
#   skills.commit-style = ./skills/commit-style;
#   packages = [ pkgs.uv pkgs.pandoc ];
# };
# ```
#
# :::caution[No secrets in MCP declarations]
# `env` and `headers` end up in the world-readable Nix store.
# :::

{ lib, config, ... }:
let
  cfg = config.darkone.host.ai-space;
  inherit (lib) mkOption types;

  # Subset of HM `programs.mcp.servers` that OpenClaw (`mcp.servers`) reads too.
  mcpServer = types.submodule {
    options = {
      command = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Executable of a local (stdio) server.";
      };
      args = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Arguments of `command`.";
      };
      env = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Environment of a local server (no secrets: Nix store).";
      };
      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Endpoint of a remote (HTTP/SSE) server.";
      };
      headers = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "HTTP headers of a remote server (no secrets: Nix store).";
      };
    };
  };
in
{
  options = {
    darkone.host.ai-space = {
      enable = lib.mkEnableOption "AI space host (isolated agents workspace)";

      mcp = mkOption {
        type = types.attrsOf mcpServer;
        default = { };
        description = "MCP servers of the space: OpenClaw and members' Claude Code / Codex.";
      };

      skills = mkOption {
        type = types.attrsOf (types.either types.lines types.path);
        default = { };
        description = ''
          Skills of the space, by name: inline `SKILL.md`, a `SKILL.md` file or
          a skill directory. Given to OpenClaw and members' Claude Code / Codex.
        '';
      };

      enableClaude = mkOption {
        type = types.bool;
        default = true;
        description = "Claude Code for members and for OpenClaw (coding-agent delegation).";
      };

      enableCodex = mkOption {
        type = types.bool;
        default = true;
        description = "Codex CLI for members and for OpenClaw (coding-agent delegation).";
      };

      packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Tools of the space: OpenClaw PATH and members' homes.";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # Services of `host.services` are triggered by the server profile.
    darkone.host.server.enable = true;
    darkone.system.sops.isolated = lib.mkDefault true;
  };
}
