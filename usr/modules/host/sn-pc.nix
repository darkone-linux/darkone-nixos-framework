{ lib, config, ... }:
let
  cfg = config.darkone.host.sn-pc;
in
{
  options = {
    darkone.host.sn-pc.enable = lib.mkEnableOption "SN workstations";
  };

  config = lib.mkIf cfg.enable {

    # Darkone modules
    darkone = {

      # Based on laptop framework profile
      host.desktop.enable = true;

      # Advanced user (developper / admin)
      theme.advanced.enable = true;
      theme.office.enable = true;
      #theme.teenager.enable = true;

      # No email software
      graphic.packages.enableEmail = false;

      # Virtualbox
      #graphic.virtualbox.enable = true;

      # Music creation
      #graphic.music.enable = true;
    };

    # Host specific state version
    system.stateVersion = "24.11";
  };
}
