# The core DNF module.
#
# :::caution
# This module is enabled by default (required by DNF configuration).
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
    && network.gateway ? services
    && builtins.elem "ncps" network.gateway.services
    && host.hostname != network.gateway.hostname;
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
    darkone.system.core.enableBoost = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable overclocking, corectl";
    };
    darkone.system.core.enableKmscon = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable nerd font for TTY";
    };
  };

  # Core module for DNF machines
  config = lib.mkIf cfg.enable {

    # Bootloader (enabled by default, but not with RPI dependencies)
    boot = lib.mkIf cfg.enableSystemdBoot {
      loader = {
        timeout = 3;
        systemd-boot = {
          enable = true;
          configurationLimit = lib.mkOverride 1337 10; # Less than mkDefault
        };
        efi.canTouchEfiVariables = true;
      };
    };

    # Hostname and firewall
    networking.hostName = host.hostname;
    networking.firewall = {
      enable = cfg.enableFirewall;
      allowPing = lib.mkDefault true;
      allowedTCPPorts = lib.mkDefault [ 22 ];
      allowedUDPPorts = lib.mkDefault [ ];
    };

    # Enable the host profile
    darkone.host.${host.profile}.enable = true;

    # Users are not mutable from sops installation (use config.yaml + just)
    users.mutableUsers = false;

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
      extraConfig = "font-size=14";
    };

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
    powerManagement = lib.mkIf cfg.enableBoost {
      cpuFreqGovernor = "performance";
      powertop.enable = true;
    };

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
  };
}
