# NixOS configuration for the local LAN administrator.

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
      colmena
      deadnix
      just
      nixfmt-rfc-style
      php84
      php84Packages.composer
      statix
      wakeonlan
    ];

    # Optimized switch (perl -> rust)
    system.switch = {
      enable = false;
      enableNg = true;
    };

    # Allow unfree packages
    nixpkgs.config.allowUnfree = true;

    # Using experimental flakes and nix
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    # We trust users to allow send configurations
    nix.settings.trusted-users = [
      "root"
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

    # We need ssh agent to deploy nodes
    programs.ssh.startAgent = true;
  };
}
