{ lib, config, ... }:
let
  cfg = config.darkone.host.sn-pc;
in
{
  options = {
    darkone.host.sn-pc.enable = lib.mkEnableOption "SN workstations";
  };

  config = lib.mkIf cfg.enable {

    # Darkone modules for SN PCs
    darkone = {

      # Based on laptop framework profile
      host.desktop.enable = true;

      # Advanced user (developper / admin)
      theme.advanced.enable = true;
      theme.office.enable = true;
      #theme.teenager.enable = true;

      # Games activation / deactivation
      graphic.education.enableGames = false;

      # No email software
      graphic.office.enableEmail = false;

      # Virtualbox
      #graphic.virtualbox.enable = true;

      # Multimedia
      #graphic.imagery.enable = true;
      #graphic.video.enable = true;
      #graphic.music.enable = true;
    };

    # Hardware additional settings
    hardware.bluetooth.enable = lib.mkForce false;
  };
}
