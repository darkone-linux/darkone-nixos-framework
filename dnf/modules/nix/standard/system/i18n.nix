# Location and lang configuration.

{
  lib,
  config,
  network,
  ...
}:
let
  cfg = config.darkone.system.i18n;
in
{
  options = {
    darkone.system.i18n.enable = lib.mkEnableOption "Enable i18n with network configuration by default";
    darkone.system.i18n.locale = lib.mkOption {
      type = lib.types.str;
      default = "${network.locale}";
      example = "fr_FR.UTF-8";
      description = "Network locale";
    };
    darkone.system.i18n.timeZone = lib.mkOption {
      type = lib.types.str;
      default = "${network.timezone}";
      example = "Europe/Paris";
      description = "Network time zone";
    };
  };

  # Useful man & nix documentation
  config = lib.mkIf cfg.enable {

    # Configure console keymap
    console.keyMap = lib.toLower (builtins.substring 3 2 cfg.locale);

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
