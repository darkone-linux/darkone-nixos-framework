# Location and lang configuration.
#
# :::note
# By default, the configuration of this module adapts to the global configuration usr/config.yaml.
# :::

{
  lib,
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
      type = lib.types.str;
      default = "${zone.locale}";
      example = "fr_FR.UTF-8";
      description = "Network locale";
    };
    darkone.system.i18n.timeZone = lib.mkOption {
      type = lib.types.str;
      default = "${zone.timezone}";
      example = "Europe/Paris";
      description = "Network time zone";
    };
  };

  # Useful man & nix documentation
  config = lib.mkIf cfg.enable {

    # Configure console keymap
    console = {
      keyMap = lib.toLower (builtins.substring 3 2 cfg.locale);
      #useXkbConfig = true;
    };
    #services.xserver.xkb = {
    #  layout = config.console.keyMap;
    #  model = "pc104"; # TODO: auto
    #  variant = "oss"; # TODO: auto
    #  options = "terminate:ctrl_alt_bksp"
    #};

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
    };
  };
}
