# Common tools for office desktop.

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
      description = "Office packages (libreoffice)";
    };
    darkone.graphic.office.enableFirefox = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable firefox";
    };
    darkone.graphic.office.enableChromium = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable chromium";
    };
    darkone.graphic.office.enableBrave = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Brave Browser";
    };
    darkone.graphic.office.enableEmail = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Email management packages (thunderbird)";
    };
    darkone.graphic.office.huntspellLang = lib.mkOption {
      type = lib.types.str;
      default = "fr-moderne";
      example = "en-us";
      description = "Huntspell Lang (https://mynixos.com/nixpkgs/packages/hunspellDicts)";
    };
  };

  config = lib.mkIf cfg.enable {

    # Office packages
    environment.systemPackages = with pkgs; [
      dialect # Traduction
      iotas # Notes / kb software
      evince
      (lib.mkIf cfg.enableLibreOffice libreoffice-fresh)
      (lib.mkIf cfg.enableLibreOffice hunspell)
      (lib.mkIf cfg.enableLibreOffice hunspellDicts.${cfg.huntspellLang})
    ];

    # Browsers
    programs.firefox.enable = cfg.enableFirefox;
    programs.chromium.enable = cfg.enableChromium;
    darkone.system.flatpak.packages = lib.mkIf cfg.enableBrave [ "com.brave.Browser" ];

    # Thunderbird
    programs.thunderbird.enable = cfg.enableEmail;
  };
}
