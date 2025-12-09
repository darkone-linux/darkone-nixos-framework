# Common tools for office desktop.

{
  lib,
  config,
  zone,
  inputs,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.darkone.home.office;
  hasGateway = attrsets.hasAttrByPath [ "gateway" "hostname" ] zone;
in
{
  options = {
    darkone.home.office.enable = mkEnableOption "Default useful packages";
    darkone.home.office.enableEssentials = mkOption {
      type = types.bool;
      default = true;
      description = "Essential tools";
    };
    darkone.home.office.enableTools = mkOption {
      type = types.bool;
      default = false;
      description = "Little (gnome) tools (iotas, dialect, etc.)";
    };
    darkone.home.office.enableProductivity = mkOption {
      type = types.bool;
      default = false;
      description = "Productivity apps (obsidian, time management, projects, etc.)";
    };
    darkone.home.office.enableCalendarContacts = mkOption {
      type = types.bool;
      default = false;
      description = "Gnome calendar, contacts and related apps";
    };
    darkone.home.office.enableCommunication = mkOption {
      type = types.bool;
      default = false;
      description = "Communication tools";
    };
    darkone.home.office.enableOffice = mkOption {
      type = types.bool;
      default = true;
      description = "Office packages (libreoffice)";
    };
    darkone.home.office.enableFirefox = mkOption {
      type = types.bool;
      default = true;
      description = "Enable firefox";
    };
    darkone.home.office.enableChromium = mkOption {
      type = types.bool;
      default = false;
      description = "Enable chromium";
    };
    darkone.home.office.enableBrave = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Brave Browser";
    };
    darkone.home.office.enableEmail = mkOption {
      type = types.bool;
      default = true;
      description = "Email management packages (thunderbird)";
    };
    darkone.home.office.huntspellLang = mkOption {
      type = types.str;
      default = "fr-moderne";
      example = "en-us";
      description = "Huntspell Lang (https://mynixos.com/nixpkgs/packages/hunspellDicts)";
    };
  };

  config = mkIf cfg.enable {

    # Packages
    home.packages = with pkgs; [
      (mkIf (cfg.enableTools && cfg.enableCommunication) tuba) # Browse the Fediverse
      (mkIf cfg.enableCalendarContacts gnome-calendar)
      (mkIf cfg.enableCalendarContacts gnome-contacts)
      (mkIf cfg.enableEmail thunderbird)
      (mkIf cfg.enableEssentials evince) # Reader
      (mkIf cfg.enableEssentials gnome-calculator)
      (mkIf cfg.enableOffice hunspell)
      (mkIf cfg.enableOffice hunspellDicts.${cfg.huntspellLang})
      (mkIf cfg.enableOffice libreoffice-fresh) # Force visible icon theme
      (mkIf cfg.enableProductivity super-productivity) # Time processing
      (mkIf cfg.enableTools authenticator) # Two-factor authentication code generator
      (mkIf cfg.enableTools dialect) # translate
      (mkIf cfg.enableTools gnome-characters)
      (mkIf cfg.enableTools gnome-decoder) # Scan and generate QR codes
      (mkIf cfg.enableTools gnome-font-viewer)
      (mkIf cfg.enableTools gnome-maps)
      (mkIf cfg.enableTools gnome-secrets)
      (mkIf cfg.enableTools gnome-weather)
      (mkIf cfg.enableTools iotas) # Simple note taking with mobile-first design and Nextcloud sync
      (mkIf cfg.enableTools pika-backup) # Simple backups based on borg -> Security ?
      (mkIf cfg.enableTools simple-scan)
      (mkIf cfg.enableTools snapshot) # Webcam
      (mkIf cfg.enableProductivity obsidian)
      (mkIf cfg.enableCommunication zoom-us)
      (mkIf cfg.enableBrave brave)
    ];

    # Hack to set Colibre icons instead of dark icon with light theme
    home.file.".config/libreoffice/4/user/registrymodifications.init.xcu".text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="SymbolStyle" oor:op="fuse"><value>colibre</value></prop></item>
      </oor:items>
    '';
    systemd.user.tmpfiles.rules = [
      "L ${config.home.homeDirectory}/.config/libreoffice/4/user/registrymodifications.xcu - - - - ${config.home.homeDirectory}/.config/libreoffice/4/user/registrymodifications.init.xcu"
    ];

    # Browsers
    # TODO: https://nix-community.github.io/home-manager/options.xhtml#opt-programs.firefox.languagePacks
    # TODO: https://nix-community.github.io/home-manager/options.xhtml#opt-programs.chromium.dictionaries

    programs.firefox = mkIf cfg.enableFirefox {
      enable = true;
      package = pkgs.firefox-esr;
      languagePacks = [ "${zone.lang}" ];
      profiles = {
        default = {
          id = 0;
          name = "default";
          isDefault = true;
          settings = {
            "browser.startup.homepage" = mkIf hasGateway "http://${zone.gateway.hostname}";
            "browser.search.defaultenginename" = "google";
            "browser.search.order.1" = "google";
            "browser.aboutConfig.showWarning" = false;
            "browser.compactmode.show" = true;
            #"extensions.bitwarden.enable" = true; -> TODO: install bitwarden

            # Firefox 75+ remembers the last workspace it was opened on as part of its session management.
            # This is annoying, because I can have a blank workspace, click Firefox from the launcher, and
            # then have Firefox open on some other workspace.
            "widget.disable-workspace-management" = true;
          };
          search = {
            force = true;
            default = "google";
            order = [
              "google"
              "duckduckgo"
              "nix-options"
              "nix-packages"
            ];
            engines = {
              nix-options = {
                name = "Nix Options";
                urls = [
                  {
                    template = "https://search.nixos.org/options";
                    params = [
                      {
                        name = "channel";
                        value = "unstable";
                      }
                      {
                        name = "query";
                        value = "{searchTerms}";
                      }
                    ];
                  }
                ];
                icon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
                definedAliases = [ "@no" ];
              };
              nix-packages = {
                name = "Nix Packages";
                urls = [
                  {
                    template = "https://search.nixos.org/packages";
                    params = [
                      {
                        name = "channel";
                        value = "unstable";
                      }
                      {
                        name = "query";
                        value = "{searchTerms}";
                      }
                    ];
                  }
                ];
                icon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
                definedAliases = [ "@np" ];
              };
              google.metaData.alias = "@g";
            };
          };
          extensions = {
            force = true;
            packages = with inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system}; [
              bitwarden
              #darkreader
              #browserpass
              ublock-origin
            ];
            settings."uBlock0@raymondhill.net".settings = {
              selectedFilterLists = [
                "ublock-filters"
                "ublock-badware"
                "ublock-privacy"
                "ublock-unbreak"
                "ublock-quick-fixes"
              ];
            };
          };
        };
      };
      policies = {
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        PasswordManagerEnabled = false;
        DontCheckDefaultBrowser = true;
        DisablePocket = true;
        SearchBar = "unified";
        ExtensionSettings = {
          "bitwarden@bitwarden.com" = {
            installation_mode = "force_installed";
          };
        };
      };
    };

    # Chromium (wip) - not working
    programs.chromium = lib.mkIf cfg.enableChromium {
      enable = true;
      #package = pkgs.ungoogled-chromium;
      extensions = [
        "aapbdbdomjkkjkaonfhkkikfgjllcleb" # Google Translate
        "gcbommkclmclpchllfjekcdonpmejbdp" # https everywhere
        "cjpalhdlnbpafiamejdnhcphjbkeiagm" # ublock origin
        "oldceeleldhonbafppcapldpdifcinji" # Language tool
        "gppongmhjkpfnbhagpmjfkannfbllamg" # Wappalyzer
        "nfkmalbckemmklibjddenhnofgnfcdfp" # Channel Blocker
        "hdannnflhlmdablckfkjpleikpphncik" # Youtube Speed Control
        "bbeaicapbccfllodepmimpkgecanonai" # Block Tube
        "jjnkmicfnfojkkgobdfeieblocadmcie" # Tube Archivist companion
        "mnjggcdmjocbbbhaepdhchncahnbgone" # SponsorBlock
        "icallnadddjmdinamnolclfjanhfoafe" # Fast Forward
        "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
      ];
      dictionaries = [
        pkgs.hunspellDictsChromium.fr_FR
        pkgs.hunspellDictsChromium.en_US
      ];
    };

    # TODO: Thunderbird profile
    #programs.thunderbird.enable = cfg.enableEmail;
  };
}
