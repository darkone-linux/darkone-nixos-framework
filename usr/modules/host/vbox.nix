# VBOX virtual machine profile

{ lib, config, ... }:
let
  cfg = config.darkone.host.vbox;
in
{
  options = {
    darkone.host.vbox.enable = lib.mkEnableOption "A personalized virtualbox config";
  };

  config = lib.mkIf cfg.enable {

    # Darkone modules
    darkone = {

      # Virtualbox VM
      host.vm.enableVirtualbox = true;

      # For advanced users
      theme.advanced.enable = true;
    };

    system.stateVersion = "25.05";
  };
}
