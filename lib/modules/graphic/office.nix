{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.office;
in
{
  # WIP
  options = {
    darkone.graphic.office.enable = lib.mkEnableOption "Default useful packages";

    darkone.graphic.office.enableLibreOffice = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = "Office packages (libreoffice)";
    };
    darkone.graphic.office.enableInternet = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = "Internet packages (firefox)";
    };
    darkone.graphic.office.enableEmail = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = "Email management packages (thunderbird)";
    };
  };

  config = lib.mkIf cfg.enable {

    # Office packages
    environment.systemPackages =
      with pkgs;
      [
        dialect # Traduction
        iotas # Notes / kb software
      ]
      ++ (
        if cfg.enableLibreOffice then
          [
            libreoffice-fresh
            hunspell
            hunspellDicts.fr-moderne
          ]
        else
          [ ]
      );

    # Firefox
    programs.firefox.enable = cfg.enableInternet;

    # Thunderbird
    programs.thunderbird.enable = cfg.enableEmail;
  };
}
