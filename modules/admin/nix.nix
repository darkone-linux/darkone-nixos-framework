# NixOS configuration for the local LAN administrator computer.
#
# :::tip[Build farm (remote builders)]
# An admin host builds every node closure locally and pushes it (`buildOnTarget`
# empty, see `assets/just/project.just`), so it is the machine that actually
# compiles. Any fleet host flagged `build-farm` in `config.yaml` becomes one of
# its `nix.buildMachines`, reached over SSH as the `nix` deploy user.
#
# Delegation is deliberately narrow. `mandatoryFeatures` (default
# `big-parallel`) means the farm is offered **only** the derivations that
# declare `requiredSystemFeatures = [ "big-parallel" ]` — kernel, chromium,
# firefox, llvm, rustc… ie. the long builds a beefy host is wanted for. Anything
# else stays local, which matters when the farm sits behind a slow uplink: only
# the requested output travels back.
#
# Never drop `big-parallel` from this host's own `nix.settings.system-features`
# to force delegation: keeping it means an unreachable farm makes the build hook
# decline and the derivation is simply built locally instead of failing.
#
# :::caution[Deploy key required]
# `sshKey` points at the shared deploy key `just configure-admin-host` generates
# under the `nix` user's home. Admin hosts hold it by construction; a host that
# enables this module without the key logs SSH failures on every delegated build.
# :::
#
# :::note[Why not a binary cache]
# A `harmonia` on the farm would share its build results, but harmonia serves the
# *whole* `/nix/store` and cannot express "only what I compiled": it captures
# traffic the public cache should answer. Offloading is a build-scheduling
# concern, not a substitution one — hence `buildMachines` here and a last-resort
# substituter priority in `service/nix-cache.nix`.
# :::

{
  lib,
  config,
  pkgs,
  dnfLib,
  host,
  hosts,
  ...
}:
let
  cfg = config.darkone.admin.nix;
  farmCfg = cfg.remoteBuilders;

  # Fleet hosts declared as build farms, minus this one: an admin host is itself
  # a candidate farm (a second deployer is a legitimate setup) and must never
  # delegate to itself.
  farms = lib.filter (h: ((h.features or { }) ? "build-farm") && h.hostname != host.hostname) hosts;
in
{
  options = {
    darkone.admin.nix.enable = lib.mkEnableOption "Enable NIX configuration builder tools";
    darkone.admin.nix.enableNh = lib.mkEnableOption "Enable nix helper (nh) management tool";

    darkone.admin.nix.remoteBuilders = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Offload builds to the fleet hosts flagged `build-farm` in
          `config.yaml`. Inert while no host carries the flag.
        '';
      };

      maxJobs = lib.mkOption {
        type = lib.types.int;
        default = 8;
        description = "Parallel build slots to use on each farm.";
      };

      speedFactor = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Relative speed rating of a farm, compared to this host.";
      };

      mandatoryFeatures = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "big-parallel" ];
        description = ''
          Features a derivation MUST require for a farm to be offered it. This
          is what keeps small derivations off a remote (possibly slow) link.
          An empty list sends every eligible derivation to the farm.
        '';
      };

      supportedFeatures = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "big-parallel"
          "kvm"
          "nixos-test"
          "benchmark"
        ];
        description = "System features a farm can provide.";
      };

      systems = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "x86_64-linux" ];
        description = ''
          Platforms a farm builds for. Explicit rather than derived: `hosts.nix`
          only carries an architecture when it differs from the default.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # Allow unfree packages
    nixpkgs.config.allowUnfree = true;

    # Legacy `<nixpkgs>` on the search path for `nix-shell` expressions
    # (e.g. `doc/shell.nix`). Flake-only admin hosts define no channel, so
    # pin `<nixpkgs>` to the exact revision that built this system.
    nix.nixPath = [ "nixpkgs=${pkgs.path}" ];

    # Large updates / downloads
    # https://nix.dev/manual/nix/2.22/command-ref/conf-file.html?highlight=substit#conf-download-buffer-size
    nix.settings.download-buffer-size = 524288000; # 500 MiB

    # Nix package indexer for the "nix-locate" command
    programs.nix-index = {
      enable = true;
      enableZshIntegration = true;
    };

    # NOTE: already in home admin entries but not working
    #programs.gnupg.agent = {
    #  enable = true;
    #  enableSSHSupport = true;
    #  pinentryPackage = pkgs.pinentry-curses;
    #};

    # Nix helper tool
    programs.nh = lib.mkIf cfg.enableNh {
      enable = true;
      clean = {
        enable = true;
        dates = "weekly";
        extraArgs = "--keep-since 7d --keep 3";
      };
    };
    environment.shellAliases = lib.mkIf cfg.enableNh { rebuild = "nh os switch /etc/nixos/"; };

    # We need an ssh agent to deploy nodes
    programs.ssh.startAgent = !config.services.gnome.gcr-ssh-agent.enable;

    #--------------------------------------------------------------------------
    # Build farm
    #--------------------------------------------------------------------------

    # Root (nix-daemon) reaches the farm as `nix@<addr>`, which the `Match user
    # nix` stanza of `system/core.nix` already covers: that criterion matches the
    # *remote* user, so no extra host-key handling is needed here.
    nix.buildMachines = lib.mkIf farmCfg.enable (
      map (h: {
        hostName = dnfLib.preferredIp h;
        sshUser = "nix";
        sshKey = "${config.users.users.nix.home}/.ssh/id_ed25519";
        protocol = "ssh-ng";
        inherit (farmCfg)
          maxJobs
          speedFactor
          systems
          supportedFeatures
          mandatoryFeatures
          ;
      }) farms
    );

    nix.distributedBuilds = lib.mkIf (farmCfg.enable && farms != [ ]) true;

    # Let the farm fetch build inputs from its own substituters instead of
    # having this host upload the whole input closure to it — the difference
    # between a few MB of derivations and gigabytes over an ADSL uplink.
    nix.settings.builders-use-substitutes = lib.mkIf farmCfg.enable true;
  };
}
