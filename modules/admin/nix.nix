# NixOS configuration for the local LAN administrator computer.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.admin.nix;
in
{
  options = {
    darkone.admin.nix.enable = lib.mkEnableOption "Enable NIX configuration builder tools";
    darkone.admin.nix.enableNh = lib.mkEnableOption "Enable nix helper (nh) management tool";
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
  };
}
