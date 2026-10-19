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
#   mcp.github = {
#     command = "github-mcp-server";
#     args = [ "stdio" ];
#     secretEnv = [ "GITHUB_PERSONAL_ACCESS_TOKEN" ]; # sops: mcp/github/<VAR>
#   };
#   skills.commit-style = ./skills/commit-style;
#   packages = [ pkgs.uv pkgs.pandoc pkgs.github-mcp-server ];
# };
# ```
#
# :::caution[Secrets: `secretEnv` only]
# `env` and `headers` end up in the world-readable Nix store. `secretEnv`
# reads the space's sops file, for local servers: a remote server takes no
# secret.
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
      secretEnv = mkOption {
        type = types.listOf (types.strMatching "[A-Za-z_][A-Za-z0-9_]*");
        default = [ ];
        example = [ "GITHUB_TOKEN" ];
        description = ''
          Secret environment of a local server: each variable read from the
          space's sops file, key `mcp/<server>/<VAR>` (`just space-sops <host>`).
        '';
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

    # Members (group `users`) read them through Home Manager, OpenClaw through
    # its env file.
    sops.secrets = lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (
          name: server:
          map (
            var:
            lib.nameValuePair "mcp/${name}/${var}" {
              group = "users";
              mode = "0440";
            }
          ) server.secretEnv
        ) cfg.mcp
      )
    );

    # Here rather than in a member's home: the space fails, named, even without
    # members.
    assertions = lib.concatLists (
      lib.mapAttrsToList (name: server: [
        {
          assertion = (server.command != null) != (server.url != null);
          message = "darkone.host.ai-space.mcp.${name}: set exactly one of `command` (local) or `url` (remote).";
        }
        {
          assertion =
            server.url == null || (server.args == [ ] && server.env == { } && server.secretEnv == [ ]);
          message = "darkone.host.ai-space.mcp.${name}: `args`, `env` and `secretEnv` are for a local server (`command`).";
        }
        {
          assertion = server.headers == { } || server.url != null;
          message = "darkone.host.ai-space.mcp.${name}: `headers` is for a remote server (`url`).";
        }
        {
          assertion = server.secretEnv == [ ] || builtins.match "[A-Za-z0-9_-]+" name != null;
          message = "darkone.host.ai-space.mcp.${name}: a server with `secretEnv` needs a name of letters, digits, `-` and `_` (sops key, env name).";
        }
      ]) cfg.mcp
    );
  };
}
