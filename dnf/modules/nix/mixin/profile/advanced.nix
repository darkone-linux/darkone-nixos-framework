# Profile for advanced users (computer scientists, developers, admins).

{ lib, config, ... }:
let
  cfg = config.darkone.profile.advanced;
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

      # Graphical
      graphic.gnome = lib.mkIf config.darkone.graphic.gnome.enable {
        enableTechnicalFeatures = lib.mkDefault true;
      };
    };

    # Additional tools
    programs = {
      iotop.enable = lib.mkDefault true;
      less.enable = lib.mkDefault true;
      htop.enable = lib.mkDefault true;
      bat.enable = lib.mkDefault true;
    };
  };
}
