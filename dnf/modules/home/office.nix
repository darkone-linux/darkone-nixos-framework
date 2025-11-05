# Common tools for office desktop.

{
  lib,
  config,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.darkone.home.office;
in
{
  options = {
    darkone.home.office.enable = lib.mkEnableOption "Default useful packages";

    darkone.home.office.enableTools = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Little (gnome) tools (iotas, dialect, etc.)";
    };
    darkone.home.office.enableProductivity = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Productivity apps (time management, projects, etc.)";
    };
    darkone.home.office.enableCalendarContacts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Gnome calendar, contacts and related apps";
    };
    darkone.home.office.enableCommunication = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Communication tools";
    };
    darkone.home.office.enableLibreOffice = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Office packages (libreoffice)";
    };
    darkone.home.office.enableFirefox = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable firefox";
    };
    darkone.home.office.enableChromium = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable chromium";
    };
    darkone.home.office.enableBrave = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Brave Browser";
    };
    darkone.home.office.enableEmail = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Email management packages (thunderbird)";
    };
    darkone.home.office.huntspellLang = lib.mkOption {
      type = lib.types.str;
      default = "fr-moderne";
      example = "en-us";
      description = "Huntspell Lang (https://mynixos.com/nixpkgs/packages/hunspellDicts)";
    };
  };

  config = lib.mkIf cfg.enable {

    # Packages
    home.packages = with pkgs; [
      (lib.mkIf (cfg.enableTools && cfg.enableCommunication) tuba) # Browse the Fediverse
      (lib.mkIf cfg.enableCalendarContacts gnome-calendar)
      (lib.mkIf cfg.enableCalendarContacts gnome-contacts)
      (lib.mkIf cfg.enableEmail thunderbird)
      (lib.mkIf cfg.enableLibreOffice hunspell)
      (lib.mkIf cfg.enableLibreOffice hunspellDicts.${cfg.huntspellLang})
      (lib.mkIf cfg.enableLibreOffice libreoffice-fresh)
      (lib.mkIf cfg.enableProductivity super-productivity) # Time processing
      (lib.mkIf cfg.enableTools authenticator) # Two-factor authentication code generator
      (lib.mkIf cfg.enableTools dialect) # translate
      (lib.mkIf cfg.enableTools evince) # Reader
      (lib.mkIf cfg.enableTools gnome-decoder) # Scan and generate QR codes
      (lib.mkIf cfg.enableTools gnome-font-viewer)
      (lib.mkIf cfg.enableTools gnome-maps)
      (lib.mkIf cfg.enableTools gnome-secrets)
      (lib.mkIf cfg.enableTools gnome-weather)
      (lib.mkIf cfg.enableTools iotas) # Simple note taking with mobile-first design and Nextcloud sync
      (lib.mkIf cfg.enableTools pika-backup) # Simple backups based on borg -> Security ?
      (lib.mkIf cfg.enableTools simple-scan)
    ];

    # Browsers
    # TODO: https://nix-community.github.io/home-manager/options.xhtml#opt-programs.firefox.languagePacks
    # TODO: https://nix-community.github.io/home-manager/options.xhtml#opt-programs.chromium.dictionaries

    programs.firefox = {
      enable = cfg.enableFirefox;
      enableGnomeExtensions = osConfig.services.desktopManager.gnome.enable;
    };
    programs.chromium.enable = cfg.enableChromium;
    services.flatpak.packages = lib.mkIf cfg.enableBrave [ "com.brave.Browser" ];

    # TODO: Thunderbird profile
    #programs.thunderbird.enable = cfg.enableEmail;
  };
}
