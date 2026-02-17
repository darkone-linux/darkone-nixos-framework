# NixOS configuration for the local LAN administrator computer.

{ lib, config, ... }:
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

    # Large updates / downloads
    # https://nix.dev/manual/nix/2.22/command-ref/conf-file.html?highlight=substit#conf-download-buffer-size
    nix.settings.download-buffer-size = 524288000; # 500 MiB

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
