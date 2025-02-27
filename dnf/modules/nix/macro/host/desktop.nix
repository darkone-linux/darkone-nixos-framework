# A full desktop configuration with gnome, multimedia and office tools.

{ lib, config, ... }:
let
  cfg = config.darkone.host.desktop;
in
{
  options = {
    darkone.host.desktop.enable = lib.mkEnableOption "Desktop optimized host configuration";
  };

  config = lib.mkIf cfg.enable {

    # Load minimal configuration
    darkone.host.minimal.enable = lib.mkDefault true;

    # System additional features
    darkone.system = {
      core.enableFstrim = lib.mkDefault true;
      core.enableBoost = lib.mkDefault false;
    };

    # Daemons
    darkone.service = {
      audio.enable = lib.mkDefault true;
      printing.enable = lib.mkDefault true;
    };

    # Graphical applications
    darkone.graphic = {
      gnome.enable = lib.mkDefault true;
      obsidian.enable = lib.mkDefault true;
      office.enable = lib.mkDefault true;
      office.enableEmail = lib.mkDefault true;
      office.enableLibreOffice = lib.mkDefault true;
      office.enableInternet = lib.mkDefault true;
    };
  };
}
