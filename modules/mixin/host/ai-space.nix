# AI space: headless host running the agents of one space (owner + members).
#
# Server base with secrets isolated from the fleet: agents read untrusted
# input (mail, web, chat), so the host only decrypts its own
# `usr/secrets/hosts/<hostname>.yaml`. Usually a microVM guest
# (`features: ["microvm-guest:<hypervisor>"]`), bare metal works too.
#
# Agent tooling, declared once per space (`usr/machines/<host>/configuration.nix`)
# and shared by the OpenClaw assistant and every member's Claude Code / Codex /
# OpenCode (`darkone.home.aiSpace`, on by default in the `space-member` home):
#
# - `mcp`: MCP servers, local (`command`) or remote (`url`);
# - `skills`: `SKILL.md` content, a file or a skill directory, by name;
# - `enableClaude`, `enableCodex`, `enableOpenCode`: CLIs for members and for
#   OpenClaw delegation;
# - `packages`: tools on the agents' PATH and in members' homes;
# - `projectsDir`: shared projects, writable by every member and the agent
#   (group `projects`, setgid, default ACL), `~/projects` in members' homes.
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

{
  lib,
  config,
  dnfLib,
  host,
  users,
  ...
}:
let
  cfg = config.darkone.host.ai-space;
  members = lib.filter (u: users ? ${u}) (dnfLib.spaceMembers host);
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
        description = "MCP servers of the space: OpenClaw and members' Claude Code / Codex / OpenCode.";
      };

      skills = mkOption {
        type = types.attrsOf (types.either types.lines types.path);
        default = { };
        description = ''
          Skills of the space, by name: inline `SKILL.md`, a `SKILL.md` file or
          a skill directory. Given to OpenClaw and members' Claude Code / Codex /
          OpenCode.
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

      enableOpenCode = mkOption {
        type = types.bool;
        default = true;
        description = "OpenCode for members and for OpenClaw (coding-agent delegation).";
      };

      packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Tools of the space: OpenClaw PATH and members' homes.";
      };

      projectsDir = mkOption {
        type = types.str;
        default = "/var/lib/projects";
        description = ''
          Shared projects of the space: every member and the OpenClaw agent
          (its working dir) read and write them, `~/projects` in members' homes.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # Services of `host.services` are triggered by the server profile.
    darkone.host.server.enable = true;
    darkone.system.sops.isolated = lib.mkDefault true;

    # Members trust each other: group rights whatever the umask (`0077` of the
    # OpenClaw unit), through setgid and a default ACL.
    users.groups.projects.members =
      members ++ lib.optional config.darkone.service.openclaw.enable "openclaw";
    systemd.tmpfiles.settings."10-ai-space-projects".${cfg.projectsDir} = {
      d = {
        mode = "2770";
        user = "root";
        group = "projects";
      };
      "a+".argument = lib.concatStringsSep "," [
        "default:user::rwx"
        "default:group::rwx"
        "default:group:projects:rwx"
        "default:mask::rwx"
        "default:other::---"
      ];
    };

    # Repositories owned by another member or the agent: git refuses them
    # otherwise (`dubious ownership`).
    programs.git = {
      enable = true;
      config.safe.directory = [ "${cfg.projectsDir}/*" ];
    };

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
