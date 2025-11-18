# The core DNF module.
#
# :::danger[Required module]
# This module is enabled by default (required by DNF configuration).
# It is required for the proper functioning of every NixOS computer on the local network.
# :::

{
  lib,
  config,
  host,
  network,
  pkgs,
  ...
}:
let
  cfg = config.darkone.system.core;

  # Current host is a client and not the gateway, but network have a gateway with ncps activated
  isNcpsClient =
    cfg.enableGatewayClient
    && network ? local-substituter
    && network.local-substituter != null
    && network.local-substituter != host.hostname;
in
{
  options = {
    darkone.system.core.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Darkone framework core system (activated by default)";
    };
    darkone.system.core.enableSystemdBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the default boot loader";
    };
    darkone.system.core.enableFstrim = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "SSD optimisation with fstrim";
    };
    darkone.system.core.enableFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable firewall (default true)";
    };
    darkone.system.core.enableSops = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable sops dnf module (default true)";
    };
    darkone.system.core.enableGatewayClient = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Configuration optimized for local gateway (ncps client...)";
    };
    darkone.system.core.enableFlatpak = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable flatpak DNF configuration (only for graphic environments)";
    };
    darkone.system.core.enableKmscon = lib.mkEnableOption {
      type = lib.types.bool;
      default = true;
      description = "Enable nerd font for TTY";
    };
    darkone.system.core.enableBoost = lib.mkEnableOption "Enable overclocking, corectl";
    darkone.system.core.enableAutoSuspend = lib.mkEnableOption "Enable automatic suspend (for laptops, ignored if disableSuspend is true)";
    darkone.system.core.disableSuspend = lib.mkEnableOption "Full suspend disable (for servers)";
  };

  # Core module for DNF machines
  config = lib.mkIf cfg.enable {

    # Bootloader (enabled by default, but not with RPI dependencies)
    boot = lib.mkIf cfg.enableSystemdBoot {

      # Last linux kernel
      kernelPackages = pkgs.linuxPackages_latest;

      loader = {
        timeout = lib.mkDefault 3;
        systemd-boot = {
          enable = true;
          editor = false;
          configurationLimit = lib.mkOverride 1337 10; # Less than mkDefault
        };
        efi.canTouchEfiVariables = true;
      };
    };

    # Global networking
    networking = {
      hostName = host.hostname;
      firewall = {
        enable = cfg.enableFirewall;
        allowPing = lib.mkDefault true;
        allowedTCPPorts = [ 22 ];
        allowedUDPPorts =
          if host.hostname == network.gateway.hostname then
            [ ]
          else
            [
              2757
              2759
            ]; # TMP: STK
      };
    };

    # Enable the host profile
    darkone.host.${host.profile}.enable = true;

    # Users are not mutable from sops installation (use config.yaml + just)
    users.mutableUsers = false;

    # The specific user "nix" is declared in config.yaml and have this key on each host
    users.users.nix.openssh.authorizedKeys.keyFiles = [ ./../../../../usr/secrets/nix.pub ];

    # Nerd fond for gnome terminal and default monospace
    fonts.packages = with pkgs; [ nerd-fonts.jetbrains-mono ];
    fonts.fontconfig.enable = true;

    # Nerd font for TTY
    services.kmscon = lib.mkIf cfg.enableKmscon {
      enable = true;
      fonts = [
        {
          name = "JetBrainsMono Nerd Font Mono";
          package = pkgs.nerd-fonts.jetbrains-mono;
        }
      ];
      extraOptions = "--term xterm-256color";
      extraConfig = ''
        font-size=18
        xkb-layout=fr
        xkb-variant=oss
        xkb-model=pc104
      '';
      useXkbConfig = false;
    };
    #security.loginDefs.settings.ERASECHAR = "0x08";

    # To manage nodes, openssh must be activated
    services.openssh.enable = true;

    # Write installed packages in /etc/installed-packages
    environment.etc."installed-packages".text =
      let
        packages = builtins.map (p: "${p.name}") config.environment.systemPackages;
        sortedUnique = builtins.sort builtins.lessThan (pkgs.lib.lists.unique packages);
        formatted = builtins.concatStringsSep "\n" sortedUnique;
      in
      formatted;

    # SOPS DNF module
    darkone.system.sops.enable = cfg.enableSops;

    # Overclocking & performance optimisations (WIP)
    programs.corectrl = lib.mkIf cfg.enableBoost {
      enable = true;
      gpuOverclock.enable = true;
    };

    # Enable performance mode and more boot power
    powerManagement.cpuFreqGovernor = lib.mkIf cfg.enableBoost "performance";

    # Disable powermanagement if disableSuspend but not boost
    powerManagement.enable = (!cfg.disableSuspend) || cfg.enableBoost;

    # SSD optimisations
    services.fstrim = lib.mkIf cfg.enableFstrim {
      enable = true;
      interval = "daily";
    };

    # Enable NCPS client configuration if needed
    darkone.service.ncps = lib.mkIf isNcpsClient {
      enable = true;
      isClient = true;
    };

    # Flatpak configuration for DNF
    darkone.system.flatpak.enable = cfg.enableFlatpak && config.darkone.graphic.gnome.enable;

    # Disable suspend for servers
    # TODO: wakeonlan from suspend?
    systemd.targets = {
      sleep.enable = !cfg.disableSuspend;
      suspend.enable = !cfg.disableSuspend;
      hibernate.enable = !cfg.disableSuspend;
      hybrid-sleep.enable = !cfg.disableSuspend;
    };
    systemd.sleep = lib.mkIf cfg.disableSuspend {
      extraConfig = ''
        AllowSuspend=no
        AllowHibernation=no
        AllowHybridSleep=no
        AllowSuspendThenHibernate=no
      '';
    };

    # Suspend: by default do not sleep / suspend to manage hosts through the network
    # https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html
    services.logind.settings.Login =
      if cfg.enableAutoSuspend then
        {
          IdleAction = "suspend-then-hibernate";
          IdleActionSec = "20min";
          HibernateDelaySec = "2h";
        }
      else
        {
          IdleAction = "ignore";
          IdleActionSec = "0";
        };

    # Authorize wheel members to halt & reboot
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.isInGroup("wheel") &&
            (
              action.id == "org.freedesktop.login1.reboot-ignore-inhibitors" ||
              action.id == "org.freedesktop.login1.power-off-ignore-inhibitors" ||
              action.id == "org.freedesktop.login1.halt-ignore-inhibitors"
            )) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
