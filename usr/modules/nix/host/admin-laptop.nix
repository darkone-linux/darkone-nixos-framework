{ lib, config, ... }:
let
  cfg = config.darkone.host.admin-laptop;
in
{
  options = {
    darkone.host.admin-laptop.enable = lib.mkEnableOption "Darkone administration laptop";
  };

  config = lib.mkIf cfg.enable {

    # Darkone modules
    darkone = {

      # Based on laptop framework profile
      host.laptop.enable = true;

      # Advanced user (developper / admin)
      theme.advanced.enable = true;

      # Nix administration features
      admin.nix.enable = true;

      # Printers
      #service.printing.enableHpPrinters = true;

      # No email software
      graphic.office.enableEmail = false;

      # Virtualbox
      #graphic.virtualbox.enable = true;

      # Music creation
      #graphic.music.enable = true;

      # Gnome options
      #graphic.gnome.enableDashToDock = true;
      #graphic.gnome.enableGsConnect = true;
      #graphic.gnome.enableCaffeine = true;
    };

    # Host specific state version
    system.stateVersion = "24.05";
  };
}
