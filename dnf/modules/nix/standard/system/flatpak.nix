# Flatpak software management.

{ lib, config, ... }:
let
  cfg = config.darkone.system.flatpak;
in
{
  options = {
    darkone.system.flatpak.packages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "com.brave.Browser" ];
      description = "List of packages to install";
    };
  };

  # Enable and install flatpak if needed
  config = lib.mkIf (cfg.packages != [ ]) {
    services.flatpak = {
      enable = true;
      uninstallUnmanaged = true;
      inherit (cfg) packages;
      update.auto.enable = true; # Default is weekly
      overrides = {
        global = {

          # Force Wayland by default
          Context.sockets = [
            "wayland"
            "!x11"
            "!fallback-x11"
          ];

          Environment = {

            # Fix un-themed cursor in some Wayland apps
            XCURSOR_PATH = "/run/host/user-share/icons:/run/host/share/icons";

            # Force correct theme for some GTK apps
            GTK_THEME = "Adwaita:dark";
          };
        };
      };
    };
  };
}
