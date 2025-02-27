# Documentation (man) for developers and admins.

{ lib, config, ... }:
let
  cfg = config.darkone.system.documentation;
in
{
  options = {
    darkone.system.documentation.enable = lib.mkEnableOption "Enable useful technical documentation (man, nixos)";
  };

  # Useful man & nix documentation
  config = lib.mkIf cfg.enable {
    documentation = {
      enable = true;
      doc.enable = false;
      dev.enable = false;
      info.enable = false;
      nixos.enable = true;

      man = {
        enable = true;
        man-db.enable = false;
        mandoc.enable = true;
        generateCaches = true;
      };
    };
  };
}
