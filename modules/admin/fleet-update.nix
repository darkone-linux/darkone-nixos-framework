# Fleet update tool (`fleet-update`) and its unattended daily run.
#
# `enable` installs the tool on a deployment host; `just fleet-update` then
# runs it. `timer.enable` adds a daily `fleet-update --no-ui` run: flake
# update, build, test by waves, switch.
#
# :::caution[Service identity]
# The run belongs to `user`, owner of `workDir`: git identity, sops age key,
# AI and Matrix credentials. It needs passwordless `sudo` (`just clean`
# permissions, `nix` deploy identity whose key lives in `~nix/.ssh`).
# :::
#
# :::tip[AI tools]
# `--ai-model` launches `claude` or `opencode` from `PATH`. Declare what the
# unattended run may reach in `aiPackages`; without it the run warns once and
# carries on without AI.
# :::
#
# :::note[Exit codes]
# `4` (a run already holds the lock) counts as success: no alert. Any other
# failure fails the unit and raises the existing `SystemdUnitFailed` alert,
# as does a run still going after `timer.timeout`.
# :::
#
# :::tip[Enable on the admin host]
# ```nix
# darkone.admin.fleet-update = {
#   enable = true;
#   user = "admin";
#   timer.enable = true;
# };
# ```
# :::

{
  lib,
  config,
  pkgs,
  pkgs-stable,
  dnfLib,
  ...
}:
let
  cfg = config.darkone.admin.fleet-update;

  # `nix-eval-jobs` built against the system Nix: another minor fails to
  # evaluate a consumer repository holding a git submodule
  # (`mismatch in field 'narHash'`, `dnf/lib/nix-tools.nix`).
  nixEvalJobs = dnfLib.pickForNix {
    candidates = [
      pkgs.nix-eval-jobs
      pkgs-stable.nix-eval-jobs
    ];
    nix = config.nix.package;
  };

  # `PATH` of `just clean` (statix, deadnix, generate, treefmt) and of the
  # tool, explicit: a system unit sees neither the dev shell nor the user's
  # profile. `cargo`, `rustc`, `gcc`: `just generate` from `src/generator`
  # (codev). `curl`, `jq`: `just send-msg` of `--send-report`.
  runner = pkgs.writeShellApplication {
    name = "fleet-update-unattended";
    runtimeInputs = [
      cfg.package
      config.nix.package
      pkgs.bash
      pkgs.cargo
      pkgs.coreutils
      pkgs.curl
      pkgs.deadnix
    ]
    ++ lib.optional (pkgs ? dnf-generator) pkgs.dnf-generator
    ++ cfg.aiPackages
    ++ [
      pkgs.findutils
      pkgs.gcc
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.just
      pkgs.nixfmt
      pkgs.rustc
      pkgs.statix
      pkgs.treefmt
    ];

    # `sudo` and `ping` are setuid/capability wrappers, never store paths.
    text = ''
      export PATH="/run/wrappers/bin:$PATH"
      exec fleet-update --no-ui "$@"
    '';
  };
in
{
  options = {
    darkone.admin.fleet-update = {
      enable = lib.mkEnableOption "fleet-update, the fleet update and deployment tool";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.fleet-update.override { nix-eval-jobs = nixEvalJobs; };
        defaultText = lib.literalExpression "pkgs.fleet-update";
        description = ''
          The fleet-update package. Its `nix-eval-jobs` is matched to the
          system Nix: the tool evaluates the consumer flake with it.
        '';
      };

      aiPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        example = lib.literalExpression "[ pkgs.opencode ]";
        description = ''
          AI tools reachable from the unattended run (`--ai-model`). Optional:
          the tool warns and goes on without AI when none is found.

          Not a dependency of the package, because `pkgs.claude-code` is
          unfree and would force `allowUnfree` on every consumer.
          `pkgs.opencode` is MIT.
        '';
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "admin";
        description = ''
          Account running the unattended update: owner of `workDir`, holding
          the git identity, the sops age key and the AI and Matrix credentials.
        '';
      };

      workDir = lib.mkOption {
        type = lib.types.str;
        default = "/etc/nixos";
        description = ''
          Consumer workspace on disk. Not the `workDir` module argument, which
          is its copy in the nix store.
        '';
      };

      timer = {
        enable = lib.mkEnableOption "the daily unattended run (`fleet-update --no-ui`)";

        onCalendar = lib.mkOption {
          type = lib.types.str;
          default = "*-*-* 04:00";
          description = "When the run starts (systemd `OnCalendar`).";
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;

          # `--send-report` once the pinned package sends it: the release train
          # flips this default with the version, never before.
          default = [ ];
          example = [
            "--on"
            "+server"
          ];
          description = "Options passed after `--no-ui`, which the module always sets.";
        };

        timeout = lib.mkOption {
          type = lib.types.str;
          default = "6h";
          description = ''
            Longest run before systemd stops it (`TimeoutStartSec`). A hung
            run would otherwise hold the lock, and every later run would exit
            `4` without any alert.
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ cfg.package ];

        assertions = [
          {
            assertion = dnfLib.matchesNix {
              package = nixEvalJobs;
              nix = config.nix.package;
            };
            message = "darkone.admin.fleet-update: no nix-eval-jobs built against Nix ${config.nix.package.version} (nixpkgs: ${pkgs.nix-eval-jobs.version}, stable: ${pkgs-stable.nix-eval-jobs.version}); set nix.package to a matching Nix.";
          }
        ];
      }

      (lib.mkIf cfg.timer.enable {
        assertions = [
          {
            assertion = cfg.user != null;
            message = "darkone.admin.fleet-update.timer needs darkone.admin.fleet-update.user (owner of workDir).";
          }
          {
            assertion = config.darkone.admin.nix.enable;
            message = "darkone.admin.fleet-update.timer runs on a deployment host: enable darkone.admin.nix.";
          }
          {
            assertion = pkgs ? dnf-generator;
            message = "darkone.admin.fleet-update.timer needs pkgs.dnf-generator, x86_64-linux only.";
          }
        ];

        systemd.services.fleet-update = {
          description = "DNF fleet update (unattended)";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];

          # The deployment host is part of the fleet: its own switch must not
          # stop the run that activates it.
          restartIfChanged = false;

          serviceConfig = {
            Type = "oneshot";
            User = cfg.user;
            WorkingDirectory = cfg.workDir;
            ExecStart = "${lib.getExe runner} ${lib.escapeShellArgs cfg.timer.extraArgs}";
            SuccessExitStatus = [ 4 ];
            TimeoutStartSec = cfg.timer.timeout;

            # SIGTERM to the tool only: it stops its children and records the
            # run as interrupted, resumable with `--resume`.
            KillMode = "mixed";
          };
        };

        # Not `Persistent`: a host powered off at the scheduled time must not
        # deploy the fleet at boot.
        systemd.timers.fleet-update = {
          wantedBy = [ "timers.target" ];
          timerConfig.OnCalendar = cfg.timer.onCalendar;
        };
      })
    ]
  );
}
