# Location and lang configuration.
#
# :::note
# By default, the configuration of this module adapts to the global configuration usr/config.yaml.
# The locale must follow the canonical `xx_YY.UTF-8` shape (eg. `fr_FR.UTF-8`)
# so the language and country codes can be safely derived for the console
# keymap, XKB layout, and Nextcloud phone region defaults.
# :::

{
  lib,
  config,
  zone,
  ...
}:
let
  cfg = config.darkone.system.i18n;

  # Match `xx_YY.UTF-8`, capturing language (group 0) and country (group 1).
  # `strMatching` on the option already rejects malformed values at evaluation
  # time, so the match is guaranteed to succeed here.
  localeRegex = "^([a-z]{2})_([A-Z]{2})\\.UTF-8$";
  localeParts = builtins.match localeRegex cfg.locale;
  countryCode = builtins.elemAt localeParts 1;
in
{
  options = {
    darkone.system.i18n.enable = lib.mkEnableOption "Enable i18n with network zone configuration by default";
    darkone.system.i18n.locale = lib.mkOption {
      type = lib.types.strMatching localeRegex;
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

  # Useful man & nix documentation
  config = lib.mkIf cfg.enable {

    # Configure console keymap.
    # The country code is used as the keymap name (eg. `FR` -> `fr`), which
    # matches the kbd convention for the locales DNF supports.
    console = {
      keyMap = lib.toLower countryCode;
      #useXkbConfig = true;
    };

    # Cf. config gnome
    #services.xserver.xkb = {
    #  layout = config.console.keyMap;
    #  model = "pc104"; # TODO: auto
    #  variant = "oss"; # TODO: auto
    #  options = "terminate:ctrl_alt_bksp"
    #};

    # Fix gnome apps deadkeys for french keyboard (êâë...)
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
