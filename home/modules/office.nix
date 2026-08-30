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
    makeBinPath
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
  # `nextcloud.enable` default without recursing through the option system.
  detectedNextcloud = dnfLib.serviceHref {
    name = "nextcloud";
    inherit network hosts;
    preferZone = zone.name;
  };
  nextcloudUrl = if cfg.nextcloud.server != null then cfg.nextcloud.server else detectedNextcloud;
  hasNextcloud = cfg.nextcloud.enable && nextcloudUrl != null;
  hasNextcloudWebdav = hasNextcloud && cfg.nextcloud.enableWebdav;

  # Search path of the client unit, overriding the profile-only one
  # home-manager pins.
  #
  # The wizard's "Open" button ends in `xdg-open`, whose GNOME branch is
  # guarded by `command -v gio`. Without glib it silently falls through to the
  # generic branch, which probes a hardcoded browser list (`firefox`,
  # `chromium`, `www-browser`...) that a NixOS profile shipping `firefox-esr`
  # never satisfies: `xdg-open: no method available for opening <url>`, and a
  # login-flow token minted for nothing.
  #
  # That failure is what makes "Copy link" look broken too: every click on
  # either button mints a *new* token and the client only polls the last one,
  # so a link copied after a few dead "Open" attempts is already superseded
  # server-side and lands on "Unauthorized".
  nextcloudClientPath = concatStringsSep ":" [
    (makeBinPath [
      pkgs.glib
      pkgs.xdg-utils
    ])
    "${config.home.profileDirectory}/bin"
  ];

  # Nextcloud account helper (files, calendar, contacts).
  #
  # Nextcloud refuses to mint an app password from the web UI for an OIDC
  # user: it asks to confirm a local password that does not exist
  # (user_oidc#468). Login Flow v2 is the documented way around it — the very
  # one the desktop client uses — and it is a plain HTTP API, so a script can
  # drive it and hand the result to GNOME Online Accounts.
  #
  # GOA rather than a GTK bookmark: `modules/graphic/gnome.nix` already turns
  # it on whenever the network carries a cloud, it mounts the share on its
  # own, and the same entry feeds Evolution over CalDAV/CardDAV. A bookmark
  # would only add a credential-less duplicate of that mount.
  nextcloudWebdavLogin = pkgs.writeShellApplication {
    name = "nextcloud-webdav-login";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
      glib
      jq
      libsecret
      xdg-utils
    ];
    text = ''
      server="${toString nextcloudUrl}"
      host="''${server#*://}"
      host="''${host%%/*}"
      goa_conf="''${XDG_CONFIG_HOME:-$HOME/.config}/goa-1.0/accounts.conf"

      # Login Flow v2: anonymous POST, then poll while the user authenticates
      # in the browser. The User-Agent names the app password server-side.
      init="$(curl -fsS -X POST -A "DNF $(uname -n)" "$server/index.php/login/v2")"
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

      # The Nextcloud uid, which is what GOA authenticates with. Never assume
      # it matches the local account: user_oidc derives it from the provider,
      # and a user may well run their services under another login.
      login_name="$(jq -r .loginName <<< "$result")"
      app_password="$(jq -r .appPassword <<< "$result")"

      # Derived from the server, so re-running refreshes the account in place
      # instead of stacking a second one next to it.
      account="account_$(printf '%s' "$server" | cksum | cut -d' ' -f1)_0"

      # Seed the keyring first: rewriting the config file is what makes the
      # daemon reload, so the credential has to already be there. GOA reads a
      # GVariant vardict, and jq supplies the string escaping.
      if ! printf "{'password': <%s>}" "$(jq -n --arg p "$app_password" '$p')" \
        | secret-tool store --label="GOA owncloud credentials for identity $account" \
            xdg:schema org.gnome.OnlineAccounts \
            goa-identity "owncloud:gen0:$account"
      then
        echo "Trousseau inaccessible : compte non enregistré." >&2
        exit 1
      fi

      # Rewrite our own block only; any other account in the file is kept.
      mkdir -p "$(dirname "$goa_conf")"
      touch "$goa_conf"
      tmp="$(mktemp)"
      awk -v drop="[Account $account]" '
        $0 == drop { skip = 1; next }
        /^\[/ { skip = 0 }
        !skip
      ' "$goa_conf" > "$tmp"

      # Mirrors what the GOA "Nextcloud" provider writes itself, explicit port
      # included; the provider is still named `owncloud` internally.
      #
      # `Identity` is the credential half and must stay the Nextcloud uid;
      # `PresentationIdentity` is display only, and gvfs reuses it verbatim to
      # name the mount. Left to the provider's `uid@host` default that reads
      # as `IDM-<uuid>@cloud.example.com` in the file manager sidebar,
      # hence an explicit, human label.
      cat >> "$tmp" <<EOF

      [Account $account]
      Provider=owncloud
      Identity=$login_name
      PresentationIdentity=Nextcloud ($host)
      Uri=https://$host:443/remote.php/webdav/
      FilesEnabled=true
      CalendarEnabled=true
      CalDavUri=https://$host:443/remote.php/dav/
      ContactsEnabled=true
      CardDavUri=https://$host:443/remote.php/dav/
      AcceptSslErrors=false
      EOF
      mv "$tmp" "$goa_conf"
      chmod 644 "$goa_conf"

      # Wakes the daemon when it is not running; when it is, its own file
      # monitor has already picked the account up.
      gdbus introspect --session --dest org.gnome.OnlineAccounts \
        --object-path /org/gnome/OnlineAccounts >/dev/null 2>&1 || true

      echo ""
      echo "  Compte Nextcloud : $login_name"
      echo "  Serveur          : $host"
      echo ""
      echo "Fichiers, agenda et contacts sont reliés à ce compte ; le partage"
      echo "apparaît dans le gestionnaire de fichiers."
      echo ""
      echo "Mot de passe d'application, pour tout autre client WebDAV :"
      echo ""
      echo "    $app_password"
    '';
  };

  # Drops the GTK bookmark the client plants on its sync folder.
  #
  # `Utility::setupFavLink` appends `file://<syncdir>` to the GTK bookmarks
  # the first time a folder is configured, which lands right next to the
  # entry the file manager already shows for the same account: two sidebar
  # rows, one target. Only the bookmark is ours to remove.
  #
  # The sync roots are read back from the client's own config rather than
  # from `syncDir`: the wizard lets the user pick any folder, and this must
  # still match what they chose.
  nextcloudDropSyncBookmark = pkgs.writeShellApplication {
    name = "nextcloud-drop-sync-bookmark";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      gnused
    ];
    text = ''
      conf_home="''${XDG_CONFIG_HOME:-$HOME/.config}"
      bookmarks="$conf_home/gtk-3.0/bookmarks"
      client_conf="$conf_home/Nextcloud/nextcloud.cfg"

      if [ ! -f "$bookmarks" ] || [ ! -f "$client_conf" ]; then
        exit 0
      fi

      # `0\Folders\1\localPath=/home/me/Nextcloud/`, one line per sync root.
      roots="$(sed -n 's/^[0-9]*\\Folders\\[0-9]*\\localPath=//p' "$client_conf")"
      if [ -z "$roots" ]; then
        exit 0
      fi

      tmp="$(mktemp)"
      while IFS= read -r line; do

        # `URI [label]`, percent-encoded once the file manager has rewritten
        # the file; `%b` turns `%C3%A9` back into the raw UTF-8 bytes.
        uri="''${line%% *}"
        target="''${uri#file://}"
        target="$(printf '%b' "''${target//%/\\x}")"
        keep=1
        while IFS= read -r root; do
          if [ -n "$root" ] && [ "''${target%/}" = "''${root%/}" ]; then
            keep=0
          fi
        done <<< "$roots"
        if [ "$keep" = 1 ]; then
          printf '%s\n' "$line"
        fi
      done < "$bookmarks" > "$tmp"

      # Rewrite only on a real change: the path unit driving this watches the
      # very file being written.
      if ! cmp -s "$tmp" "$bookmarks"; then
        cat "$tmp" > "$bookmarks"
      fi
      rm -f "$tmp"
    '';
  };

  # Opens the client's settings dialog when the tray icon is out of reach.
  #
  # Client 34 moved every action out of the window: what a launcher opens is
  # `ActivitiesWindow`, a read-only feed whose header is a plain label (no
  # button, no menu), and the account/sync entries live only in the tray
  # icon's menu. Lose that icon and the settings become unreachable — no
  # command-line flag opens them, and on Wayland `showQtTrayPopup()` bails out
  # ("Wayland cannot create an arbitrary QWidget popup from a tray
  # activation") back to that same read-only window, as does relaunching the
  # binary through the single-instance MSG_SHOWMAINDIALOG.
  #
  # `UnsetEnvironment` on the unit below keeps the icon alive, so this is a
  # fallback rather than the main door: no launcher, just a command. It leans
  # on the actions the client exports on the freedesktop CloudProviders bus
  # (`Implements=org.freedesktop.CloudProviders` in its desktop entry),
  # `opensettings` among them, which need no tray at all.
  nextcloudSettings = pkgs.writeShellApplication {
    name = "nextcloud-settings";
    runtimeInputs = with pkgs; [
      coreutils
      glib
      gnugrep
      systemd
    ];
    text = ''
      bus="com.nextcloudgmbh.Nextcloud"
      root="/com/nextcloudgmbh/Nextcloud"

      # Start the unit before touching the bus. The name is D-Bus activatable
      # (the package ships a .service for it), so a bare call would spawn an
      # instance outside the unit, hence without the PATH its browser login
      # needs — see `nextcloudClientPath`. No-op when the client is up.
      systemctl --user start nextcloud-client || true

      # The action group belongs to the running process, which needs a moment
      # to claim the name on a cold start.
      for _ in $(seq 60); do
        if gdbus introspect --session --dest "$bus" --object-path "$root" >/dev/null 2>&1; then
          break
        fi
        sleep 0.5
      done

      # One `Folder/<n>` object per account, each exposing the same actions.
      managed="$(gdbus call --session --dest "$bus" --object-path "$root" \
        --method org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null || true)"
      account="$(printf '%s' "$managed" | grep -o "$root/Folder/[0-9]\+" | head -n1 || true)"

      if [ -z "$account" ]; then
        echo "Aucun compte Nextcloud connecté : ouvrez d'abord le client." >&2
        exit 1
      fi

      gdbus call --session --dest "$bus" --object-path "$account" \
        --method org.gtk.Actions.Activate opensettings "[]" "{}" >/dev/null
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
    darkone.home.office.enableProductivity = mkEnableOption "Productivity apps (obsidian, time mgm, projects, etc.)";
    darkone.home.office.enableCommunication = mkEnableOption "Communication tools";
    darkone.home.office.enableOffice = mkEnableOption "Office packages (libreoffice, huntspell, fonts...)";
    darkone.home.office.enableFirefox = mkEnableOption "Enable firefox";
    darkone.home.office.enableLibreWolf = mkEnableOption "Enable LibreWolf (firefox alternative)";
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

    # Nextcloud desktop integration. Binds the account and nothing else: a
    # user with a large account on several machines must stay in control of
    # what actually lands on each disk.
    darkone.home.office.nextcloud = {
      enable = mkOption {
        type = types.bool;
        default = detectedNextcloud != null;
        description = "Install the Nextcloud desktop client, pre-bound to the network instance";
      };
      server = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://cloud.example.com";
        description = ''
          Nextcloud instance the client binds to. `null` picks the one declared
          on the network (this zone first). Set it to target a local or external
          instance instead.
        '';
      };
      enableAutoStart = mkOption {
        type = types.bool;
        default = true;
        description = "Start the Nextcloud client in the background on login";
      };
      enableWebdav = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Ship `nextcloud-webdav-login`, a one-shot helper that authenticates
          through the browser (Kanidm SSO) and registers the result as a GNOME
          Online Account: files over WebDAV in the file manager, plus calendar
          and contacts in Evolution. Needed because Nextcloud refuses to create
          an app password from its web UI for an OIDC user.

          The helper also prints the app password, so any other WebDAV client
          can be pointed at the same account.

          :::note[GNOME only]
          The account is written where GNOME Online Accounts reads it, which
          `darkone.graphic.gnome` enables on its own as soon as the network
          carries a cloud. On another desktop the printed password stays usable.
          :::

          Ignored when `darkone.home.office.nextcloud.enable` is off.
        '';
      };
      syncDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Nextcloud";
        description = ''
          Local folder pre-filled in the setup wizard, relative to `$HOME`.

          :::caution[No sync by default]
          Left `null` on purpose. The wizard then stops on its folder page and
          the user decides what, if anything, to synchronise. Setting it skips
          that page.
          :::
        '';
      };
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
      (mkIf cfg.enableOffice libreoffice-stable) # Force visible icon theme
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
      (mkIf hasNextcloud nextcloudSettings)
      (mkIf hasNextcloudWebdav nextcloudWebdavLogin)
      (mkIf hasVaultwarden bitwarden-cli)
    ];

    assertions = [
      {
        assertion = !cfg.nextcloud.enable || nextcloudUrl != null;
        message = ''
          darkone.home.office.nextcloud.enable is on but no Nextcloud instance
          could be resolved. Declare a `nextcloud` service on the network, or
          point darkone.home.office.nextcloud.server at an explicit URL.
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

    # The wizard pre-fill flags are a one-shot *configuration* command, not
    # launch options: `application.cpp` writes them to the client config then
    # calls `std::exit(0)`. Passing them to ExecStart therefore configures the
    # client and never runs it, so they belong in ExecStartPre — which leaves
    # the home-manager ExecStart (`nextcloud --background`) alone.
    #
    # Pre-filling the server is what lets an account be bound without shipping
    # a password: the wizard jumps straight to browser authentication (Kanidm
    # SSO), which mints an app password of its own.
    #
    # `--overridelocaldir` stays out unless explicitly asked for: with the
    # server alone the wizard stops on its folder page instead of committing
    # the user to a sync.
    systemd.user.services.nextcloud-client = mkIf hasNextcloud {

      # `-`: a failed pre-fill must not cost the user their client. The wizard
      # then merely opens with an empty server field.
      Service.ExecStartPre =
        "-"
        + concatStringsSep " " (
          [
            "${pkgs.nextcloud-client}/bin/nextcloud"
            "--overrideserverurl ${toString nextcloudUrl}"
          ]
          ++ optional (
            cfg.nextcloud.syncDir != null
          ) "--overridelocaldir ${config.home.homeDirectory}/${toString cfg.nextcloud.syncDir}"
        );

      # Without this the wizard's "Open" button cannot reach a browser, see
      # `nextcloudClientPath`.
      Service.Environment = mkForce [ "PATH=${nextcloudClientPath}" ];

      # Restores the tray icon, which is where every action lives since v34.
      #
      # `modules/graphic/gnome.nix` sets `qt.platformTheme = "gnome"`, i.e.
      # `QT_QPA_PLATFORMTHEME=gnome`, which loads QGnomePlatform. Its
      # `createPlatformSystemTrayIcon()` is a hardcoded `return nullptr`
      # (`xor %eax,%eax; ret`), so `QSystemTrayIcon::isSystemTrayAvailable()`
      # is false and `Systray::create()` skips the icon altogether — no icon,
      # hence no menu, hence no way to the settings dialog. Dropping the
      # variable falls back to Qt's own GNOME theme, which does return a real
      # `QDBusTrayIcon`.
      #
      # Scoped to this unit on purpose: the same nullptr breaks the tray of
      # every Qt application on the fleet, but widening the fix means changing
      # how all of them are themed.
      Service.UnsetEnvironment = "QT_QPA_PLATFORMTHEME";

      # Computed rather than conditional: the unit stays defined either way, so
      # `systemctl --user start nextcloud-client` still works when auto-start
      # is off.
      Install.WantedBy = mkForce (optional cfg.nextcloud.enableAutoStart "graphical-session.target");
    };

    # Watch the bookmarks file rather than patch it once: the client writes
    # its entry when the user finishes the wizard, long after activation.
    systemd.user.services.nextcloud-drop-sync-bookmark = mkIf hasNextcloud {
      Unit = {
        Description = "Remove the duplicate Nextcloud sync folder bookmark";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${nextcloudDropSyncBookmark}/bin/nextcloud-drop-sync-bookmark";
      };

      # Also on login: `PathChanged` never fires for a file already sitting
      # there when the path unit starts.
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };

    systemd.user.paths.nextcloud-drop-sync-bookmark = mkIf hasNextcloud {
      Unit = {
        Description = "Watch the GTK bookmarks for the Nextcloud sync entry";
      };
      Path = {
        PathChanged = "${config.xdg.configHome}/gtk-3.0/bookmarks";
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };

    # The client writes its own autostart entry (`Utility::setLaunchOnStartup`,
    # called on every config migration) and that entry launches it bare, with
    # no pre-filled server, racing the unit above. `Hidden=true` is the XDG way
    # to retire an autostart entry; as a store symlink it also survives the
    # client trying to write the file back.
    xdg.configFile."autostart/Nextcloud.desktop" = mkIf hasNextcloud {
      text = ''
        [Desktop Entry]
        Type=Application
        Name=Nextcloud
        Hidden=true
      '';
    };

    # A workstation that ran the client before this module carries that entry
    # as a real file, and home-manager aborts rather than clobber one. Retire
    # it before the link check, keeping a copy: activation must not destroy
    # something the user could have edited.
    home.activation.retireNextcloudAutostart = mkIf hasNextcloud (
      lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
        entry="${config.xdg.configHome}/autostart/Nextcloud.desktop"
        if [ -f "$entry" ] && [ ! -L "$entry" ]; then
          run mv $VERBOSE_ARG "$entry" "$entry.dnf-backup"
        fi
      ''
    );

    # Connecting the account needs a credential the web UI cannot issue to an
    # OIDC user; this entry runs the Login Flow v2 helper in a terminal.
    #
    # Short name on purpose: the GNOME grid ellipsises past ~14 characters, so
    # the first word is all the user gets to tell this icon apart from the
    # sync client sitting next to it.
    xdg.desktopEntries.nextcloud-webdav-login = mkIf hasNextcloudWebdav {
      name = "Compte Nextcloud";
      genericName = "Compte en ligne";
      comment = "Relier fichiers, agenda et contacts à mon compte Nextcloud";
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
