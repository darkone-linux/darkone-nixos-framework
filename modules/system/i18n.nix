# Location and lang configuration.
#
# :::note
# Defaults follow the zone of the host (`etc/config.yaml`). The locale must have
# the canonical `xx_YY.UTF-8` shape (e.g. `fr_FR.UTF-8`): the console keymap,
# XKB layout and Nextcloud phone region derive from it.
# :::

{
  lib,
  dnfLib,
  config,
  zone,
  ...
}:
let
  cfg = config.darkone.system.i18n;

  # Never null: the option type only accepts `dnfLib.localeRegex`.
  countryCode = dnfLib.extractCountryFromLocale cfg.locale;
in
{
  options = {
    darkone.system.i18n.enable = lib.mkEnableOption "Enable i18n with network zone configuration by default";
    darkone.system.i18n.locale = lib.mkOption {
      type = lib.types.strMatching dnfLib.localeRegex;
      default = zone.locale;
      example = "fr_FR.UTF-8";
      description = "Network locale, must match the `xx_YY.UTF-8` shape.";
    };
    darkone.system.i18n.timeZone = lib.mkOption {
      type = lib.types.str;
      default = zone.timezone;
      example = "Europe/Paris";
      description = "Network time zone";
    };
  };

  # Locale, time zone and console keymap of the zone.
  config = lib.mkIf cfg.enable {

    # Country code as keymap name (`FR` -> `fr`): the kbd convention for the
    # locales DNF supports. The X11 layout follows it (`graphic/gnome.nix`).
    console.keyMap = lib.toLower countryCode;

    # Fix gnome apps deadkeys for French keyboard (êâë...)
    i18n.inputMethod = {
      enable = true;
      type = "ibus";
    };

    # Set your time zone.
    time.timeZone = cfg.timeZone;

    # Select internationalisation properties.
    i18n.defaultLocale = cfg.locale;
    i18n.extraLocaleSettings = {
      LC_ADDRESS = cfg.locale;
      LC_IDENTIFICATION = cfg.locale;
      LC_MEASUREMENT = cfg.locale;
      LC_MONETARY = cfg.locale;
      LC_NAME = cfg.locale;
      LC_NUMERIC = cfg.locale;
      LC_PAPER = cfg.locale;
      LC_TELEPHONE = cfg.locale;
      LC_TIME = cfg.locale;
      LC_ALL = cfg.locale;
    };
  };
}
