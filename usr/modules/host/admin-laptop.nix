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

      # Hp printers
      service.printing.enableHpPrinters = true;

      # No email software
      graphic.packages.enableEmail = false;

      # Virtualbox
      graphic.virtualbox.enable = true;

      # Music creation
      graphic.music.enable = true;

      # Caffeine, etc.
      graphic.gnome.enableAddExt = true;

      # I'm the master, not a node
      host.isNode = false;
    };

    # Host specific state version
    system.stateVersion = "24.05";
  };
}
