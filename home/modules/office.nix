# Office desktop: browsers, office suite, communication, cloud and PDF tools.
#
# Packages are gated by audience flags (`enableEssentials`, `enableOffice`,
# `enableTools`, `enableCommunication`...). Sub-modules (`office/`):
#
# - `browsers.nix`: Firefox ESR (LibreWolf, Chromium) with shared policies:
#   zone homepage and locale, tracking protection, Bitwarden pinned when the
#   network runs Vaultwarden.
# - `matrix.nix`: Element Desktop as soon as the network runs Matrix,
#   pre-configured (Kanidm SSO); Fractal with `enableCommunication`.
# - `nextcloud.nix`: desktop client bound to the network instance, and
#   `nextcloud-webdav-login` for GNOME Online Accounts.
# - `pandoc.nix`: `md2pdf` and the pandoc defaults (`enablePandoc`).

{
  lib,
  config,
  zone,
  network,
  pkgs,
  hosts,
  dnfLib,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    optionalString
    types
    ;
  cfg = config.darkone.home.office;

  # Locale
  inherit (zone) lang;
  country = dnfLib.extractCountryFromLocale zone.locale;

  # Homepage of this zone
  homeService = dnfLib.findService "homepage" zone.name network.services;
  homeDomain = optionalString (homeService != null) (homeService.domain or homeService.name);
  hasHomepage = homeDomain != "";
  homeUrl = optionalString hasHomepage "https://${homeDomain}.${zone.domain}";

  # Services deployed anywhere on the network
  hasService = name: lib.any (s: s.name == name) network.services;
  hasMattermost = hasService "mattermost";
  hasMatrix = hasService "matrix";
  hasVaultwarden = hasService "vaultwarden";

  # Nextcloud. `detectedNextcloud` reads only `network`/`hosts`, never an
  # option: it backs the `nextcloud.enable` default without recursion.
  detectedNextcloud = dnfLib.serviceHref {
    name = "nextcloud";
    inherit network hosts;
    preferZone = zone.name;
  };
  nextcloudUrl = if cfg.nextcloud.server != null then cfg.nextcloud.server else detectedNextcloud;
  hasNextcloud = cfg.nextcloud.enable && nextcloudUrl != null;
  hasNextcloudWebdav = hasNextcloud && cfg.nextcloud.enableWebdav;
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
    darkone.home.office.enableCalendarContacts = mkEnableOption "Calendar, contacts, tasks and related apps";
    darkone.home.office.enablePandoc = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Markdown to PDF toolchain: pandoc, typst, Gentium and DejaVu fonts,
        and the `md2pdf` command (Gentium body, A4, the zone's language).

        ```sh
        md2pdf notes.md              # A4, 10pt -> notes.pdf
        md2pdf --big notes.md        # A4, 12pt
        md2pdf --tablet notes.md     # A6, 9pt (11pt with --big), zoomed on a tablet
        md2pdf -e context notes.md   # ConTeXt engine (enablePandocContext)
        ```

        The engine is typst. It renders the raw TeX usual in notes (`\pagebreak`,
        `\placecontent`, `\centerline`...) and reports any other. Table
        columns fit their content, unless the separator dashes differ in
        length (`|--|--------|`): the widths then follow them. A bare
        `pandoc notes.md -o notes.pdf` uses the same engine, language and fonts.
        Under GNOME, the three layouts are also offered on right click in
        Nautilus (Scripts menu).
      '';
    };
    darkone.home.office.enablePandocContext = mkEnableOption "ConTeXt as an alternative PDF engine, `md2pdf -e context` (~900 MiB, needs enablePandoc)";
    darkone.home.office.pandocAuthor = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Jane Doe";
      description = "Creator written into PDFs by `md2pdf`. `null` takes the account's full name.";
    };

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

    # Matrix desktop clients auto-start (cf. office/matrix.nix)
    darkone.home.office.enableElementAutoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Auto-start Element Desktop (hidden) on login when the network runs Matrix";
    };
    darkone.home.office.enableFractalAutoStart = mkOption {
      type = types.bool;
      default = false;
      description = "Auto-start Fractal on login, with `enableCommunication` (opt-in: no background mode, its window opens)";
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

    # Values shared with the `office/` sub-modules.
    darkone.home.office.shared = mkOption {
      type = types.raw;
      internal = true;
      readOnly = true;
      default = {
        inherit
          lang
          country
          hasHomepage
          homeUrl
          hasMatrix
          hasVaultwarden
          nextcloudUrl
          hasNextcloud
          hasNextcloudWebdav
          ;
      };
      defaultText = "computed";
      description = "Office values shared with the `office/` sub-modules.";
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
      (mkIf cfg.enableCalendarContacts planify) # Tasks (note: errands -> sync activation failed)
      (mkIf cfg.enableEmail thunderbird)
      (mkIf cfg.enableEssentials celluloid) # Video player
      (mkIf cfg.enableEssentials papers) # Reader
      (mkIf cfg.enableEssentials gnome-calculator)
      (mkIf cfg.enableEssentials gnome-clocks)
      (mkIf cfg.enableEssentials gnome-usage)
      (mkIf cfg.enableFirefox gnomeExtensions.pip-on-top)
      (mkIf cfg.enableFirefox shadowfox)
      (mkIf cfg.enableOffice hunspell)
      (mkIf cfg.enableOffice hunspellDicts.${cfg.huntspellLang})
      (mkIf cfg.enableOffice inter) # Inter fonts
      (mkIf cfg.enableOffice liberation_ttf) # Liberation fonts
      (mkIf cfg.enableOffice libreoffice-stable) # Force visible icon theme
      (mkIf cfg.enableOffice lato) # Lato fonts
      (mkIf cfg.enablePandoc dejavu_fonts) # PDF code blocks: box drawing, symbols
      (mkIf cfg.enablePandoc exiftool) # PDF / image metadata
      (mkIf cfg.enablePandoc gentium) # PDF body font
      (mkIf cfg.enablePandoc librsvg) # `rsvg-convert`: SVG images in PDF output
      (mkIf cfg.enablePandoc cfg.md2pdf)
      (mkIf (cfg.enablePandoc && cfg.enablePandocContext) texliveConTeXt) # `--pdf-engine=context`
      (mkIf cfg.enablePandoc typst) # `--pdf-engine=typst`
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
      (mkIf (cfg.enableCommunication && hasMatrix) fractal)

      # `services.nextcloud-client` only defines the systemd unit; it never
      # installs the package, hence this explicit entry.
      (mkIf hasNextcloud nextcloud-client)
      (mkIf hasNextcloudWebdav cfg.nextcloud.webdavLogin)
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
    # Thunderbird
    #--------------------------------------------------------------------------

    # TODO: Thunderbird profile
    #programs.thunderbird.enable = cfg.enableEmail;
  };
}
