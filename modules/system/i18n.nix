# Location and lang configuration.
#
# :::note
# Defaults follow the zone of the host (`etc/config.yaml`). The locale must have
# the canonical `xx_YY.UTF-8` shape (e.g. `fr_FR.UTF-8`): the console keymap,
# XKB layout and Nextcloud phone region derive from it.
# :::
#
# :::tip[Keyboard of a locale]
# `dnf/config/locales.json` gives the keyboard of each locale the installer
# offers (`en_GB.UTF-8`: `uk` on the console, `gb` in XKB). Any other locale
# takes its country code (`ru_RU.UTF-8`: `ru`).
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
    darkone.system.i18n.keyboard = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default =
        if cfg.enable then
          dnfLib.keyboardFromLocale cfg.locale
        else
          {
            console = config.console.keyMap;
            xkb = config.console.keyMap;
            xkbVariant = "";
          };
      defaultText = lib.literalExpression "dnfLib.keyboardFromLocale config.darkone.system.i18n.locale";
      description = "Keyboard of the locale: `console` keymap, `xkb` layout and `xkbVariant`.";
    };
  };

  # Locale, time zone and console keymap of the zone.
  config = lib.mkIf cfg.enable {

    # The XKB layout follows it (`graphic/gnome.nix`).
    console.keyMap = cfg.keyboard.console;

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
