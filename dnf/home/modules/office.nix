# Common tools for office desktop.

{
  lib,
  config,
  zone,
  network,
  inputs,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.darkone.home.office;

  # Locale
  inherit (zone) lang;
  country = builtins.substring 3 2 zone.locale;

  # Matrix
  localMatrixServer = "https://matrix.${network.domain}";
  idmUri = "https://idm.${network.domain}";

  # Homepage (TODO: simplifier la recherche de la page d'accueil de la zone)
  homeService = findFirst (s: s.name == "homepage" && s.zone == zone.name) null network.services;
  homeDomain = optionalString (homeService != null) (
    if (hasAttr "domain" homeService) then homeService.domain else homeService.name
  );
  hasHomepage = homeDomain != "";
  homeUrl = optionalString hasHomepage "https://${homeDomain}.${zone.domain}";

  # Has services
  hasMattermost = (findFirst (s: s.name == "mattermost") null network.services) != null;
  hasMatrix = (findFirst (s: s.name == "matrix") null network.services) != null;
  hasMatrixClient = cfg.enableCommunication && hasMatrix;
  hasVaultwarden = (findFirst (s: s.name == "vaultwarden") null network.services) != null;

  # Common Firefox / Librewolf policies
  # https://mozilla.github.io/policy-templates/
  commonPolicies = {
    BlockAboutConfig = !cfg.enableUnsafeFeatures;
    BlockAboutAddons = false; # !cfg.enableUnsafeFeatures;
    CaptivePortal = false;
    DisablePocket = true;
    DisableTelemetry = true;
    DisableFirefoxStudies = true;
    DisableFirefoxAccounts = true;
    DisableMasterPasswordCreation = true;
    PasswordManagerEnabled = false;
    DontCheckDefaultBrowser = true;
    SearchBar = "unified";
    GoToIntranetSiteForSingleWordEntryInAddressBar = true;
    HttpsOnlyMode = if cfg.enableUnsafeFeatures then "enabled" else "force_enabled";
    NewTabPage = true;
    OfferToSaveLogins = false;
    OverrideFirstRunPage = mkIf hasHomepage homeUrl;
    PopupBlocking.Default = true;
    PrimaryPassword = false;
    PrivateBrowsingModeAvailability = 0; # Available, not forced
    PromptForDownloadLocation = true;
    RequestedLocales = "${lang},${lang}-${country}";
    SearchSuggestEnabled = true;
    SkipTermsOfUse = true;
    ShowHomeButton = hasHomepage;
    StartDownloadsInTempDirectory = false;
    TranslateEnabled = false;
    DisplayBookmarksToolbar = "never";

    Homepage = mkIf hasHomepage {
      URL = homeUrl;
      StartPage = "homepage";
      Locked = true;
    };

    # Search : affiche ou masque la barre de recherche sur la page d’accueil Firefox (Nouvel onglet).
    # TopSites : active ou désactive l’affichage des sites les plus visités sur la page Nouvel onglet.
    # SponsoredTopSites : autorise ou bloque l’affichage de sites sponsorisés parmi les Top Sites.
    # Highlights : affiche ou masque les éléments récents (pages visitées, téléchargements, favoris).
    # Pocket : affiche ou masque les recommandations Pocket sur la page Nouvel onglet.
    # Stories : active ou désactive le flux d’articles recommandés (Pocket/Discover).
    # SponsoredPocket : autorise ou bloque les contenus sponsorisés dans les recommandations Pocket.
    # SponsoredStories : autorise ou bloque les articles sponsorisés dans le flux Discover.
    # Snippets : affiche ou masque les messages informatifs ou promotionnels de Mozilla sur la page d’accueil.
    # Locked : empêche l’utilisateur de modifier ces paramètres depuis l’interface Firefox.
    FirefoxHome = {
      Search = true;
      TopSites = true;
      SponsoredTopSites = false;
      Highlights = true;
      Pocket = false;
      Stories = false;
      SponsoredPocket = false;
      SponsoredStories = false;
      Snippets = false;
      Locked = true;
    };

    FirefoxSuggest = {
      WebSuggestions = true;
      SponsoredSuggestions = false;
      ImproveSuggest = true;
      Locked = true;
    };

    GenerativeAI = {
      Enable = cfg.enableUnsafeFeatures;
      Chatbot = cfg.enableUnsafeFeatures;
      LinkPreviews = cfg.enableUnsafeFeatures;
      TabGroups = cfg.enableUnsafeFeatures;
      Locked = true;
    };

    PictureInPicture = {
      Enable = true;
      Locked = true;
    };

    UserMessaging = {
      ExtensionRecommendations = cfg.enableUnsafeFeatures;
      FeatureRecommendations = cfg.enableUnsafeFeatures;
      UrlbarInterventions = true; # ?
      SkipOnboarding = false; # ?
      MoreFromMozilla = false;
      FirefoxLabs = cfg.enableUnsafeFeatures;
      Locked = true;
    };

    EnableTrackingProtection = {
      Value = true;
      Locked = true;
      Cryptomining = true;
      Fingerprinting = true;
      EmailTracking = true;
      SuspectedFingerprinting = true;
    };

    # Go to about:support to obtain informations and UUID
    ExtensionSettings = {

      # Pin bitwarden
      "{446900e4-71c2-419f-a6a7-df9c091e268b}" = mkIf hasVaultwarden { default_area = "navbar"; };
    };

    # TODO: for childs
    # WebsiteFilter = {
    #   Block = [];
    #   Exceptions = [];
    # };
  };

  # Common Firefox / Librewolf settings
  commonProfileSettings = {
    "intl.accept_languages" = "${lang},${lang}-${country},en-us,en";
    "general.useragent.locale" = "${lang}";

    "extensions.pocket.enabled" = false;
    "extensions.autoDisableScopes" = 0; # Auto-install extensions!

    "browser.startup.homepage" = mkIf hasHomepage homeUrl;
    "browser.search.defaultenginename" = "google";
    "browser.search.order.1" = "google";
    "browser.aboutConfig.showWarning" = false;
    "browser.compactmode.show" = true;
    "browser.newtabpage.activity-stream.feeds.section.topstories" = false;
    "browser.newtabpage.activity-stream.feeds.snippets" = false;
    "browser.newtabpage.activity-stream.section.highlights.includePocket" = false;
    "browser.newtabpage.activity-stream.section.highlights.includeBookmarks" = false;
    "browser.newtabpage.activity-stream.section.highlights.includeDownloads" = false;
    "browser.newtabpage.activity-stream.section.highlights.includeVisited" = false;
    "browser.newtabpage.activity-stream.showSponsored" = false;
    "browser.newtabpage.activity-stream.system.showSponsored" = false;
    "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;
    "browser.newtabpage.pinned" = optional hasHomepage {
      title = zone.description;
      url = homeUrl;
    };
    "browser.contentblocking.category" = {
      Value = "strict";
      Status = "locked";
    };

    "privacy.trackingprotection.enabled" = true;
    "privacy.trackingprotection.socialtracking.enabled" = true;

    # Firefox 75+ remembers the last workspace it was opened on as part of its session management.
    # This is annoying, because I can have a blank workspace, click Firefox from the launcher, and
    # then have Firefox open on some other workspace.
    "widget.disable-workspace-management" = true;
  };
in
{
  options = {
    darkone.home.office.enable = mkEnableOption "Default useful packages";
    darkone.home.office.enableMore = mkEnableOption "More alternative packages";
    darkone.home.office.enableUnsafeFeatures = mkEnableOption "Features for advanced non-child users";
    darkone.home.office.enableUBlock = mkEnableOption "Enable ublock plugin";
    darkone.home.office.enableTools = mkEnableOption "Little (gnome) tools (iotas, dialect, etc.)";
    darkone.home.office.enableProductivity = mkEnableOption "Productivity apps (obsidian, time management, projects, etc.)";
    darkone.home.office.enableCommunication = mkEnableOption "Communication tools";
    darkone.home.office.enableOffice = mkEnableOption "Office packages (libreoffice)";
    darkone.home.office.enableFirefox = mkEnableOption "Enable firefox";
    darkone.home.office.enableLibreWolf = mkEnableOption "Enable firefox";
    darkone.home.office.enableChromium = mkEnableOption "Enable chromium";
    darkone.home.office.enableBrave = mkEnableOption "Enable Brave Browser";
    darkone.home.office.enableEmail = mkEnableOption "Email management packages (thunderbird)";
    darkone.home.office.enableCalendarContacts = mkEnableOption "Gnome calendar, contacts and related apps";

    # Enabled by default
    darkone.home.office.enableEssentials = mkOption {
      type = types.bool;
      default = true;
      description = "Essential tools";
    };

    # TODO: auto-lang
    darkone.home.office.huntspellLang = mkOption {
      type = types.str;
      default = "fr-moderne";
      example = "en-us";
      description = "[Huntspell Lang](https://mynixos.com/nixpkgs/packages/hunspellDicts)";
    };
  };

  config = mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Packages
    #--------------------------------------------------------------------------

    home.packages = with pkgs; [
      #(mkIf cfg.enableProductivity super-productivity) # Time processing -> build error
      (mkIf (cfg.enableCommunication && cfg.enableMore) tuba) # Browse the Fediverse
      (mkIf (cfg.enableCommunication && cfg.enableMore) zoom-us)
      (mkIf (cfg.enableCommunication && hasMattermost) mattermost-desktop)
      (mkIf (cfg.enableTools && cfg.enableMore) pika-backup) # Simple backups based on borg -> Security ?
      (mkIf (cfg.enableTools && cfg.enableMore) simple-scan)
      (mkIf (cfg.enableTools && !hasVaultwarden) gnome-secrets)
      (mkIf cfg.enableCalendarContacts gnome-calendar)
      (mkIf cfg.enableCalendarContacts gnome-contacts)
      (mkIf cfg.enableEmail thunderbird)
      (mkIf cfg.enableEssentials evince) # Reader
      (mkIf cfg.enableEssentials gnome-calculator)
      (mkIf cfg.enableEssentials gnome-clocks)
      (mkIf cfg.enableEssentials gnome-usage)
      (mkIf cfg.enableFirefox gnomeExtensions.pip-on-top)
      (mkIf cfg.enableFirefox shadowfox)
      (mkIf cfg.enableOffice hunspell)
      (mkIf cfg.enableOffice hunspellDicts.${cfg.huntspellLang})
      (mkIf cfg.enableOffice libreoffice-fresh) # Force visible icon theme
      (mkIf cfg.enableTools authenticator) # Two-factor authentication code generator
      (mkIf cfg.enableTools dialect) # translate
      (mkIf cfg.enableTools gnome-characters)
      (mkIf cfg.enableTools gnome-decoder) # Scan and generate QR codes
      (mkIf cfg.enableTools gnome-font-viewer)
      (mkIf cfg.enableTools gnome-maps)
      (mkIf cfg.enableTools gnome-weather)
      (mkIf cfg.enableTools iotas) # Simple note taking with mobile-first design and Nextcloud sync
      (mkIf cfg.enableTools snapshot) # Webcam
      (mkIf cfg.enableProductivity obsidian)
      (mkIf cfg.enableBrave brave)
      (mkIf hasMatrix fractal)
      (mkIf hasVaultwarden bitwarden-desktop)
      (mkIf hasVaultwarden bitwarden-cli)
    ];

    #--------------------------------------------------------------------------
    # Fixes
    #--------------------------------------------------------------------------

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

    #--------------------------------------------------------------------------
    # Matrix element desktop
    #--------------------------------------------------------------------------

    # TODO: compléter, factoriser avec element.nix
    programs.element-desktop = mkIf hasMatrixClient {
      enable = true;
      settings = {
        default_server_config = {
          "m.homeserver" = {
            base_url = localMatrixServer;
            server_name = "${network.domain} matrix server";
          };
        };
        show_labs_settings = true;
        default_theme = "dark";
        default_federate = false;
        default_country_code = country;
        room_directory.servers = [ localMatrixServer ];
        brand = network.domain;
        sso_redirect_options = {
          immediate = true;
          on_welcome_page = true;
          on_login_page = true;
        };
        oidc_static_clients."${idmUri}/".client_id = "matrix-synapse";
        oidc_metadata = {
          client_uri = idmUri;
          logo_uri = idmUri + "/pkg/img/logo.svg";
        };
      };
    };

    # Lancement automatique
    systemd.user.services.element-desktop = mkIf hasMatrixClient {
      Unit = {
        Description = "Element Desktop (autostart)";
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.element-desktop}/bin/element-desktop --no-update --hidden";
        Restart = "on-failure";
      };
    };

    #--------------------------------------------------------------------------
    # Firefox (general browser)
    #--------------------------------------------------------------------------

    # TODO: https://nix-community.github.io/home-manager/options.xhtml#opt-programs.chromium.dictionaries

    programs.firefox = mkIf cfg.enableFirefox {
      enable = true;
      package = pkgs.firefox-esr;

      # Lang https://releases.mozilla.org/pub/firefox/releases/140.7.0esr/linux-x86_64/
      languagePacks = [ "${lang}" ];

      # Default profile
      profiles = {
        default = {
          id = 0;
          name = "default";
          isDefault = true;

          # Check about:config for options.
          settings = commonProfileSettings;

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
              (mkIf hasVaultwarden bitwarden)
              (mkIf cfg.enableUBlock ublock-origin)
              (mkIf (lang == "fr") french-language-pack)
              (mkIf (lang == "fr") french-dictionary)
            ];
            settings."uBlock0@raymondhill.net".settings = mkIf cfg.enableUBlock {
              selectedFilterLists = [
                "ublock-filters"
                "ublock-badware"
                "ublock-privacy"
                "ublock-unbreak"
                "ublock-quick-fixes"
              ];
            };
          };

          # TODO: https://nix-community.github.io/home-manager/options.xhtml#opt-programs.firefox.profiles._name_.containers
          # containers = {};
        };
      };

      policies = commonPolicies;
    };

    #--------------------------------------------------------------------------
    # LibreWolf (for kids)
    #--------------------------------------------------------------------------

    programs.librewolf = mkIf cfg.enableLibreWolf {
      enable = true;

      # Lang https://releases.mozilla.org/pub/firefox/releases/140.7.0esr/linux-x86_64/
      languagePacks = [ "${lang}" ];

      # Default profile
      profiles = {
        default = {
          id = 0;
          name = "default";
          isDefault = true;

          # Check about:config for options.
          settings = commonProfileSettings;

          search = {
            force = true;
            default = "duckduckgo";
            order = [ "duckduckgo" ];
          };

          extensions = {
            force = true;
            packages = with inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system}; [
              (mkIf hasVaultwarden bitwarden)
              (mkIf (lang == "fr") french-language-pack)
              (mkIf (lang == "fr") french-dictionary)
            ];
          };

          # TODO: https://nix-community.github.io/home-manager/options.xhtml#opt-programs.firefox.profiles._name_.containers
          # containers = {};
        };
      };

      policies = commonPolicies // {
        WebsiteFilter = {
          Block = [ "<all_urls>" ];
          Exceptions = [
            "https://*.poncon.fr/*"
            "https://cdn.jsdelivr.net/*"
          ];
        };
      };
    };

    #--------------------------------------------------------------------------
    # Chromium (alternative)
    #--------------------------------------------------------------------------

    # Chromium (wip) - not working
    programs.chromium = mkIf cfg.enableChromium {
      enable = true;
      #package = pkgs.ungoogled-chromium;
      extensions = [
        "aapbdbdomjkkjkaonfhkkikfgjllcleb" # Google Translate
        "gcbommkclmclpchllfjekcdonpmejbdp" # https everywhere
        (mkIf cfg.enableUBlock "cjpalhdlnbpafiamejdnhcphjbkeiagm") # ublock origin
        "oldceeleldhonbafppcapldpdifcinji" # Language tool
        "gppongmhjkpfnbhagpmjfkannfbllamg" # Wappalyzer
        "nfkmalbckemmklibjddenhnofgnfcdfp" # Channel Blocker
        "hdannnflhlmdablckfkjpleikpphncik" # Youtube Speed Control
        "bbeaicapbccfllodepmimpkgecanonai" # Block Tube
        "jjnkmicfnfojkkgobdfeieblocadmcie" # Tube Archivist companion
        "mnjggcdmjocbbbhaepdhchncahnbgone" # SponsorBlock
        "icallnadddjmdinamnolclfjanhfoafe" # Fast Forward
        (mkIf hasVaultwarden "nngceckbapebfimnlniiiahkandclblb") # Bitwarden
      ];
      dictionaries = [
        pkgs.hunspellDictsChromium.fr_FR
        pkgs.hunspellDictsChromium.en_US
      ];
    };

    #--------------------------------------------------------------------------
    # Thunderbird
    #--------------------------------------------------------------------------

    # TODO: Thunderbird profile
    #programs.thunderbird.enable = cfg.enableEmail;
  };
}
