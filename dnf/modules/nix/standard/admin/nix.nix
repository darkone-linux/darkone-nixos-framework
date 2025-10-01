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

    # Nix / Darkone management packages
    environment.systemPackages = with pkgs; [
      age
      colmena
      deadnix
      just
      mkpasswd
      moreutils # sponge
      nixfmt-rfc-style
      php84
      php84Packages.composer
      sops
      statix
      wakeonlan
      yq
    ];

    # Allow unfree packages
    nixpkgs.config.allowUnfree = true;

    # Using experimental flakes and nix
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    # We trust users to allow send configurations
    # nix --extra-experimental-features nix-command config show | grep trusted
    nix.settings.trusted-users = [
      "root"
      "nix"
      "@wheel"
    ];

    # NOTE: already in home admin entries but not working
    #programs.gnupg.agent = {
    #  enable = true;
    #  enableSSHSupport = true;
    #  pinentryPackage = pkgs.pinentry-curses;
    #};

    # Nix helper tool
    programs.nh = lib.mkIf cfg.enable {
      enable = true;
      clean = {
        enable = true;
        dates = "weekly";
        extraArgs = "--keep-since 7d --keep 3";
      };
    };
    environment.shellAliases = lib.mkIf cfg.enable { rebuild = "nh os switch /etc/nixos/"; };

    # We need an ssh agent to deploy nodes
    programs.ssh.startAgent = !config.services.gnome.gcr-ssh-agent.enable;
  };
}
