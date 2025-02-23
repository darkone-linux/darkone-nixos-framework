{ lib, config, ... }:
let
  cfg = config.darkone.system.i18n;
in
{
  options = {
    darkone.system.i18n.enable = lib.mkEnableOption "Enable i18n";
    darkone.system.i18n.locale = lib.mkOption {
      type = lib.types.str;
      default = "fr_FR.UTF-8";
      example = "fr_FR.UTF-8";
      description = "Your locale";
    };
    darkone.system.i18n.timeZone = lib.mkOption {
      type = lib.types.str;
      default = "Europe/Paris";
      example = "America/Miquelon";
      description = "Your timezone";
    };
  };

  # Useful man & nix documentation
  config = lib.mkIf cfg.enable {

    # Configure console keymap
    console.keyMap = builtins.substring 0 2 cfg.locale;

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
