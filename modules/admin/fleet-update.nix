# Fleet update tool (`fleet-update`) and its unattended daily run.
#
# `enable` installs the tool on a deployment host; `just fleet-update` then
# runs it. `timer.enable` adds a daily `fleet-update --no-ui` run: flake
# update, build, test by waves, switch, Matrix report.
#
# :::caution[Service identity]
# The run belongs to `user`, owner of `workDir`: git identity, sops age key,
# AI and Matrix credentials. It needs passwordless `sudo` (`just clean`
# permissions, `nix` deploy identity whose key lives in `~nix/.ssh`).
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
  ...
}:
let
  cfg = config.darkone.admin.fleet-update;

  # `PATH` of `just clean` (statix, deadnix, generate, treefmt) and of the
  # tool, explicit: a system unit sees neither the dev shell nor the user's
  # profile. `cargo`, `rustc`, `gcc`: `just generate` from `src/generator` (codev).
  runner = pkgs.writeShellApplication {
    name = "fleet-update-unattended";
    runtimeInputs = [
      cfg.package
      config.nix.package
      pkgs.bash
      pkgs.cargo
      pkgs.coreutils
      pkgs.deadnix
      pkgs.dnf-generator
      pkgs.findutils
      pkgs.gcc
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
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

      package = lib.mkPackageOption pkgs "fleet-update" { };

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
          default = [ "--send-report" ];
          example = [
            "--send-report"
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
      { environment.systemPackages = [ cfg.package ]; }

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
