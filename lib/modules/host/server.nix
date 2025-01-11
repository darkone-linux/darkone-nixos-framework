{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.host.server;
  cfgLimit = 10;
in
{
  imports = [
    ./minimal.nix
  ];

  options = {
    darkone.host.server = {
      enable = lib.mkEnableOption "Server host minimal configuration";

      # Enable systemd watchdog
      enableWatchdog = lib.mkOption {
        type = lib.types.bool;
        default = true;
        example = false;
        description = "Enable systemd watchdog";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # Load minimal configuration
    darkone.host.minimal.enable = lib.mkForce true;

    # Darkone modules
    darkone.system.documentation.enable = lib.mkDefault true;

    # Default apps
    environment.systemPackages = map lib.lowPrio [
      #pkgs.dnsutils
      pkgs.curl
      pkgs.wget
      pkgs.htop
      pkgs.vim
      pkgs.zellij
    ];

    # Restrict the number of boot entries to prevent full /boot partition.
    # Servers don't need too many generations.
    boot.loader.grub.configurationLimit = lib.mkDefault cfgLimit;
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault cfgLimit;

    # Firewall is enabled
    darkone.system.core.enableFirewall = true;

    # Delegate the hostname setting to dhcp/cloud-init by default.
    #networking.hostName = lib.mkOverride 1337 ""; # lower prio than lib.mkDefault

    # If the user is in @wheel they are trusted.
    nix.settings.trusted-users = [
      "root"
      "@wheel"
    ];

    # Given that our systems are headless, emergency mode is useless.
    # We prefer the system to attempt to continue booting so
    # that we can hopefully still access it remotely.
    boot.initrd.systemd.suppressedUnits = lib.mkIf config.systemd.enableEmergencyMode [
      "emergency.service"
      "emergency.target"
    ];

    systemd = {

      # Given that our systems are headless, emergency mode is useless.
      # We prefer the system to attempt to continue booting so
      # that we can hopefully still access it remotely.
      enableEmergencyMode = false;

      # https://0pointer.de/blog/projects/watchdog.html
      watchdog = lib.mkIf cfg.enableWatchdog {

        # systemd will send a signal to the hardware watchdog at half
        # the interval defined here, so every 15s.
        # If the hardware watchdog does not get a signal for 30s,
        # it will forcefully reboot the system.
        runtimeTime = "30s";

        # Forcefully reboot if the final stage of the reboot
        # hangs without progress for more than 60s.
        # https://utcc.utoronto.ca/~cks/space/blog/linux/SystemdShutdownWatchdog
        rebootTime = "60s";

        # Forcefully reboot when a host hangs after kexec.
        # This may be the case when the firmware does not support kexec.
        kexecTime = "1m";

      };

      # No sleep
      sleep.extraConfig = ''
        AllowSuspend=no
        AllowHibernation=no
      '';
    };
  };
}

# src: https://github.com/nix-community/srvos/blob/main/nixos/server/default.nix
