# Profile for advanced users (computer scientists, developers, admins).
#
# :::note[Host profile vs Home profile]
# This module enables features for all users of the system.
# Use HomeManager profiles to provide software tailored to each user (admin, advanced, student, child, teenager, etc.).
# :::

{ lib, config, ... }:
let
  cfg = config.darkone.profile.advanced;
  inherit (config.darkone.graphic) gnome;
in
{
  options = {
    darkone.profile.advanced.enable = lib.mkEnableOption "Advanced user (admin sys, developper)";
  };

  config = lib.mkIf cfg.enable {

    # DNF Modules
    darkone = {

      # System additional features
      system.documentation.enable = lib.mkDefault true;

      # Console additional features
      console = {
        git.enable = lib.mkDefault true;
        pandoc.enable = lib.mkDefault false;
        zsh.enable = lib.mkDefault true;
        packages.enable = lib.mkDefault true;
        packages.enableAdditional = lib.mkDefault true;
      };

      # Daemons
      service.httpd.enable = lib.mkDefault false;

      # Graphical tools
      graphic.gnome.enableTechnicalFeatures = lib.mkDefault gnome.enable;
    };

    # Additional tools
    programs = {
      iotop.enable = lib.mkDefault true;
      less.enable = lib.mkDefault true;
      htop.enable = lib.mkDefault true;
      bat.enable = lib.mkDefault true;
      #vscode.enable = lib.mkDefault gnome.enable; # TODO: vscode module + declarative conf
      direnv.enable = lib.mkDefault gnome.enable; # usefull for vscode plugins
    };
  };
}
