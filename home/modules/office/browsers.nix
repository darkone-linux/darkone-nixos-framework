# DNF office: Firefox ESR, LibreWolf and Chromium. Doc: `../office.nix` header.

{
  lib,
  config,
  pkgs,
  inputs,
  network,
  host,
  zone,
  ...
}:
let
  inherit (lib) mkIf optional;
  cfg = config.darkone.home.office;
  inherit (cfg.shared)
    lang
    country
    hasHomepage
    homeUrl
    hasVaultwarden
    ;

  # Common Firefox / Librewolf policies
  # https://mozilla.github.io/policy-templates/
  commonPolicies = {
    BlockAboutConfig = !cfg.enableUnsafeFeatures;
    BlockAboutAddons = false;
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

    # New Tab page content, locked against UI changes
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
      UrlbarInterventions = true;
      SkipOnboarding = false;
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

    # Open on the current workspace, not the one of the last session
    "widget.disable-workspace-management" = true;
  };
in
{
  config = mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Firefox (general browser)
    #--------------------------------------------------------------------------

    programs.firefox = mkIf cfg.enableFirefox {
      enable = true;
      package = pkgs.firefox-esr;

      # Firefox only reads ~/.mozilla/firefox (no XDG support in ESR 140, and
      # the nixpkgs wrapper forces MOZ_LEGACY_PROFILES=1). Pin the legacy path
      # explicitly: the HM 26.05 XDG default would provision a profile the
      # browser never opens (declarative extensions silently ignored).
      configPath = ".mozilla/firefox";

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

    # TEMPORARY: librewolf-151.0.2-1 is marked insecure upstream (no nixpkgs
    # maintainer). Disabled fleet-wide to keep evaluation pure; drop the
    # `&& false` once nixpkgs ships a maintained, secure build.
    programs.librewolf = mkIf (cfg.enableLibreWolf && false) {
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
            "https://*.${network.domain}/*"
            "https://cdn.jsdelivr.net/*"
            "http://127.0.0.1/*"
            "https://127.0.0.1/*"
            "http://localhost/*"
            "https://localhost/*"
            "http://${host.name}.${zone.domain}/*"
            "https://${host.name}.${zone.domain}/*"
            "http://${host.name}/*"
            "https://${host.name}/*"
            "http://[::1]/*"
            "https://[::1]/*"
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
  };
}
