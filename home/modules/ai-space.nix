# Agent tools of an AI space in a member's home: Claude Code, Codex, MCP, skills.
#
# Everything comes from the space (`darkone.host.ai-space` of the host), so
# OpenClaw and every member share the same MCP servers and skills. On by
# default in the `space-member` home; off on any other host.
#
# - MCP: HM `programs.mcp`, integrated into Claude Code and Codex;
# - skills: `~/.claude/skills`, `~/.codex/skills`;
# - logins: once per member, `claude` (`/login`), `codex login --device-auth`.
#
# :::note[Per member, per space]
# `usr/users/<login>/spaces/<host>.nix` adds or overrides, e.g. a personal MCP
# server: `programs.mcp.servers.<name> = { ... };`.
# :::

{
  lib,
  pkgs,
  config,
  osConfig,
  ...
}:
let
  cfg = config.darkone.home.aiSpace;
  space = osConfig.darkone.host.ai-space;
in
{
  options = {
    darkone.home.aiSpace.enable = lib.mkEnableOption "Agent tools of the AI space (Claude Code, Codex, MCP, skills)";
  };

  config = lib.mkIf (cfg.enable && space.enable) {
    home.packages = space.packages;

    # Always on: a member's own `programs.mcp.servers` joins the space's.
    # `secretEnv`: file refs, read at server start (HM command wrapper).
    programs.mcp = {
      enable = true;
      servers = lib.mapAttrs (
        name: server:
        removeAttrs server [ "secretEnv" ]
        // {
          env =
            server.env
            // lib.genAttrs server.secretEnv (var: {
              file = osConfig.sops.secrets."mcp/${name}/${var}".path;
            });
        }
      ) space.mcp;
    };

    # Same native binary as `darkone.home.ai`.
    programs.claude-code = lib.mkIf space.enableClaude {
      enable = true;
      package = pkgs.claude-code-nix;
      enableMcpIntegration = true;
      inherit (space) skills;
    };

    programs.codex = lib.mkIf space.enableCodex {
      enable = true;
      enableMcpIntegration = true;
      inherit (space) skills;
    };
  };
}
