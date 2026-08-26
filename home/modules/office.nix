# Common tools for office desktop.

{
  lib,
  config,
  zone,
  network,
  inputs,
  pkgs,
  host,
  hosts,
  dnfLib,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    findFirst
    hasAttr
    mkEnableOption
    mkForce
    mkIf
    mkOption
    optional
    optionalString
    types
    ;
  cfg = config.darkone.home.office;

  # Locale
  inherit (zone) lang;
  country = builtins.substring 3 2 zone.locale;

  # Matrix
  localMatrixServer = "https://matrix.${network.domain}";
  idmUri = "https://idm.${network.domain}";

  # Homepage (TODO: simplify lookup of the zone homepage)
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

  #--------------------------------------------------------------------------
  # Nextcloud (personal cloud)
  #--------------------------------------------------------------------------

  # Reads only `network`/`hosts`, never an option, so it can safely back the
  # `enableNextcloud` default without recursing through the option system.
  detectedNextcloud = dnfLib.serviceHref {
    name = "nextcloud";
    inherit network hosts;
    preferZone = zone.name;
  };
  nextcloudUrl = if cfg.nextcloudServer != null then cfg.nextcloudServer else detectedNextcloud;
  hasNextcloud = cfg.enableNextcloud && nextcloudUrl != null;
  hasNextcloudWebdav = hasNextcloud && cfg.enableNextcloudWebdav;
  nextcloudBookmark = "Nextcloud";

  # WebDAV credential helper.
  #
  # Nextcloud refuses to mint an app password from the web UI for an OIDC
  # user: it asks to confirm a local password that does not exist
  # (user_oidc#468). Login Flow v2 is the documented way around it — the very
  # one the desktop client uses — and it is a plain HTTP API, so a script can
  # drive it and hand the result to the file manager.
  nextcloudWebdavLogin = pkgs.writeShellApplication {
    name = "nextcloud-webdav-login";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      jq
      libsecret
      wl-clipboard
      xdg-utils
    ];
    text = ''
      server="${toString nextcloudUrl}"
      label="${nextcloudBookmark}"
      bookmarks="''${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks"

      # Login Flow v2: anonymous POST, then poll while the user authenticates
      # in the browser. The User-Agent names the app password server-side.
      init="$(curl -fsS -X POST -A "DNF WebDAV ($(uname -n))" "$server/index.php/login/v2")"
      login_url="$(jq -r .login <<< "$init")"
      poll_token="$(jq -r .poll.token <<< "$init")"
      poll_endpoint="$(jq -r .poll.endpoint <<< "$init")"

      echo "Autorisez l'accès dans le navigateur, puis revenez ici."
      xdg-open "$login_url" >/dev/null 2>&1 || echo "URL à ouvrir : $login_url"

      # 404 while pending, 200 once granted. The token lives 20 minutes.
      deadline="$(( $(date +%s) + 1200 ))"
      result=""
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if result="$(curl -fsS -X POST -d "token=$poll_token" "$poll_endpoint" 2>/dev/null)"; then
          break
        fi
        sleep 2
      done

      if [ -z "$result" ]; then
        echo "Délai dépassé : aucune autorisation reçue." >&2
        exit 1
      fi

      login_name="$(jq -r .loginName <<< "$result")"
      app_password="$(jq -r .appPassword <<< "$result")"

      host="''${server#*://}"
      host="''${host%%/*}"

      # Kanidm emits `preferred_username` as an SPN, so Nextcloud UIDs read
      # `login@domain`; encode the `@` rather than leave it raw in the path.
      enc_login="''${login_name//@/%40}"
      dav="davs://$host/remote.php/dav/files/$enc_login/"

      # Append, never overwrite: this file belongs to the user, who adds their
      # own bookmarks from the file manager.
      mkdir -p "$(dirname "$bookmarks")"
      touch "$bookmarks"
      if grep -qF "$dav" "$bookmarks"; then
        echo "Marque-page déjà présent."
      else
        printf '%s %s\n' "$dav" "$label" >> "$bookmarks"
        echo "Marque-page « $label » ajouté."
      fi

      # Convenience only: gvfs looks credentials up by mount spec and that
      # attribute set has drifted between releases. The credential is printed
      # below whatever happens, so a miss here costs one manual paste.
      if printf '%s' "$app_password" \
        | secret-tool store --label="Nextcloud WebDAV ($login_name)" \
            protocol davs server "$host" user "$enc_login" \
            object "remote.php/dav/files/$enc_login/" \
            domain "" port 443 authtype basic >/dev/null 2>&1
      then
        echo "Identifiants enregistrés dans le trousseau."
      else
        echo "Trousseau non pré-rempli : le gestionnaire de fichiers les demandera une fois."
      fi

      if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        printf '%s' "$app_password" | wl-copy >/dev/null 2>&1 || true
      fi

      echo ""
      echo "  Compte  : $login_name"
      echo "  Adresse : $dav"
      echo ""
      echo "  Mot de passe d'application :"
      echo ""
      echo "    $app_password"
      echo ""
      echo "Ouvrez le marque-page « $label » dans le gestionnaire de fichiers."
      echo "Si un mot de passe est demandé, collez celui ci-dessus et cochez"
      echo "« Retenir pour toujours »."
    '';
  };

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

    # Search: show/hide the search bar on the Firefox New Tab page.
    # TopSites: enable/disable showing most-visited sites on the New Tab page.
    # SponsoredTopSites: allow/block sponsored sites among the Top Sites.
    # Highlights: show/hide recent items (visited pages, downloads, bookmarks).
    # Pocket: show/hide Pocket recommendations on the New Tab page.
    # Stories: enable/disable the recommended articles feed (Pocket/Discover).
    # SponsoredPocket: allow/block sponsored content in Pocket recommendations.
    # SponsoredStories: allow/block sponsored articles in the Discover feed.
    # Snippets: show/hide Mozilla informational or promotional messages on the home page.
    # Locked: prevent the user from changing these settings from the Firefox UI.
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
    darkone.home.office.enableSecurity = mkEnableOption "Security tools (keepass)";
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

    # Matrix desktop client auto-start (Element stays the default, see below).
    darkone.home.office.enableElementAutoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Auto-start Element Desktop on login when a local Matrix server is present";
    };
    darkone.home.office.enableFractalAutoStart = mkOption {
      type = types.bool;
      default = false;
      description = "Auto-start Fractal on login when a local Matrix server is present (opt-in, see caveats below)";
    };

    # Nextcloud desktop client. Binds the account and nothing else: a user
    # with a large account on several machines must stay in control of what
    # actually lands on each disk.
    darkone.home.office.enableNextcloud = mkOption {
      type = types.bool;
      default = detectedNextcloud != null;
      description = "Install the Nextcloud desktop client, pre-bound to the network instance";
    };
    darkone.home.office.nextcloudServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://cloud.example.com";
      description = ''
        Nextcloud instance the client binds to. `null` picks the one declared
        on the network (this zone first). Set it to target a local or external
        instance instead.
      '';
    };
    darkone.home.office.enableNextcloudAutoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Start the Nextcloud client in the background on login";
    };
    darkone.home.office.enableNextcloudWebdav = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Ship `nextcloud-webdav-login`, a one-shot helper that authenticates
        through the browser (Kanidm SSO) and registers a `davs://` bookmark in
        the file manager. Needed because Nextcloud refuses to create an app
        password from its web UI for an OIDC user.

        Ignored when `enableNextcloud` is off.
      '';
    };
    darkone.home.office.nextcloudSyncDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Nextcloud";
      description = ''
        Local folder pre-filled in the setup wizard, relative to `$HOME`.

        :::caution[No sync by default]
        Left `null` on purpose. The wizard then stops on its folder page and
        the user decides what — if anything — to synchronise. Setting it skips
        that page.
        :::
      '';
    };
  };

  config = mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Packages
    #--------------------------------------------------------------------------

    home.packages = with pkgs; [
      #(mkIf cfg.enableProductivity super-productivity) # Time processing -> build error
      #(mkIf hasVaultwarden bitwarden-desktop) # TMP: Vulnerability + huge build -> electron is not maintained any more
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
      (mkIf cfg.enableEssentials showtime)
      (mkIf cfg.enableFirefox gnomeExtensions.pip-on-top)
      (mkIf cfg.enableFirefox shadowfox)
      (mkIf cfg.enableOffice hunspell)
      (mkIf cfg.enableOffice hunspellDicts.${cfg.huntspellLang})
      (mkIf cfg.enableOffice inter) # Inter fonts
      (mkIf cfg.enableOffice liberation_ttf) # Liberation fonts
      (mkIf cfg.enableOffice libreoffice-fresh) # Force visible icon theme
      (mkIf cfg.enableOffice lato) # Lato fonts
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
      (mkIf cfg.enableProductivity logseq) # official AppImage via overlay (source build broken: nixpkgs#535206)
      (mkIf cfg.enableBrave brave)
      (mkIf cfg.enableSecurity keepassxc)
      (mkIf cfg.enableSecurity keepmenu) # Dmenu/Rofi frontend for Keepass databases
      (mkIf cfg.enableSecurity gnome-secrets)
      (mkIf cfg.enableSecurity git-credential-keepassxc)
      (mkIf hasMatrix fractal)

      # `services.nextcloud-client` only defines the systemd unit; it never
      # installs the package, hence this explicit entry.
      (mkIf hasNextcloud nextcloud-client)
      (mkIf hasNextcloudWebdav nextcloudWebdavLogin)
      (mkIf hasVaultwarden bitwarden-cli)
    ];

    assertions = [
      {
        assertion = !cfg.enableNextcloud || nextcloudUrl != null;
        message = ''
          darkone.home.office.enableNextcloud is enabled but no Nextcloud
          instance could be resolved. Declare a `nextcloud` service on the
          network, or point darkone.home.office.nextcloudServer at an explicit
          URL.
        '';
      }
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
    # Matrix desktop clients
    #--------------------------------------------------------------------------

    # Element is the default Matrix client and the only one we can pre-configure.
    #
    # Fractal cannot replace it as a declarative/OIDC default because:
    #
    # - Auth mismatch: our Synapse uses legacy `oidc_providers` (`m.login.sso`,
    #   no MAS). Element supports `m.login.sso`; Fractal only supports native
    #   OIDC (MSC3861/MAS) and would need a MAS migration to authenticate.
    # - No declarative config: Element accepts a config (homeserver + OIDC);
    #   Fractal's GSettings exposes nothing equivalent, so server/OIDC cannot
    #   be pre-seeded and each user must log in interactively.
    # - No background mode: Fractal has no `--hidden`/tray, so an auto-start
    #   pops a visible window every login (hence `enableFractalAutoStart` is
    #   opt-in and off by default).

    # TODO: complete, factorize with element.nix
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

    # Auto-start Element (hidden, background-friendly client)
    systemd.user.services.element-desktop = mkIf (hasMatrixClient && cfg.enableElementAutoStart) {
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

    # Auto-start Fractal (opt-in: no --hidden, opens a visible window)
    systemd.user.services.fractal = mkIf (hasMatrix && cfg.enableFractalAutoStart) {
      Unit = {
        Description = "Fractal (autostart)";
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.fractal}/bin/fractal";
        Restart = "on-failure";
      };
    };

    #--------------------------------------------------------------------------
    # Nextcloud desktop client
    #--------------------------------------------------------------------------

    services.nextcloud-client = mkIf hasNextcloud {
      enable = true;
      startInBackground = true;
    };

    # The home-manager module hardcodes its ExecStart, and the wizard pre-fill
    # flags are the only documented way to bind an account without shipping a
    # password: the client then jumps straight to browser authentication
    # (Kanidm SSO), which mints an app password of its own.
    #
    # `--overridelocaldir` stays out unless explicitly asked for: with the
    # server alone the wizard stops on its folder page instead of committing
    # the user to a sync. The client does not persist either value, so passing
    # them on every start is the intended usage — and inert once an account
    # exists.
    systemd.user.services.nextcloud-client = mkIf hasNextcloud {
      Service.ExecStart = mkForce (
        concatStringsSep " " (
          [
            "${pkgs.nextcloud-client}/bin/nextcloud"
            "--background"
            "--overrideserverurl ${toString nextcloudUrl}"
          ]
          ++ optional (
            cfg.nextcloudSyncDir != null
          ) "--overridelocaldir ${config.home.homeDirectory}/${toString cfg.nextcloudSyncDir}"
        )
      );

      # Computed rather than conditional: the unit stays defined either way, so
      # `systemctl --user start nextcloud-client` still works when auto-start
      # is off.
      Install.WantedBy = mkForce (optional cfg.enableNextcloudAutoStart "graphical-session.target");
    };

    # Browsing files over WebDAV needs a credential the web UI cannot issue to
    # an OIDC user; this entry runs the Login Flow v2 helper in a terminal.
    xdg.desktopEntries.nextcloud-webdav-login = mkIf hasNextcloudWebdav {
      name = "Fichiers Nextcloud (connexion)";
      genericName = "Accès WebDAV";
      comment = "Autoriser l'accès à mes fichiers depuis le gestionnaire de fichiers";
      exec = "${nextcloudWebdavLogin}/bin/nextcloud-webdav-login";
      icon = "nextcloud";
      terminal = true;
      type = "Application";
      categories = [
        "Network"
        "FileTransfer"
      ];
    };

    #--------------------------------------------------------------------------
    # Firefox (general browser)
    #--------------------------------------------------------------------------

    # TODO: https://nix-community.github.io/home-manager/options.xhtml#opt-programs.chromium.dictionaries

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
