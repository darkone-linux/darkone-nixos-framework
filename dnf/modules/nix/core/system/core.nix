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
  };

  # Useful man & nix documentation
  config = lib.mkIf cfg.enable {

    # Bootloader (enabled by default, but not with RPI dependencies)
    boot = lib.mkIf cfg.enableSystemdBoot {
      loader.systemd-boot.enable = true;
      loader.efi.canTouchEfiVariables = true;
    };

    # Hostname and firewall
    networking.hostName = host.hostname;
    networking.firewall = {
      enable = cfg.enableFirewall;
      allowedTCPPorts = [ 22 ];
      allowedUDPPorts = [ ];
    };

    # Enable the host profile
    darkone.host.${host.profile}.enable = true;

    # Nerd fond for gnome terminal and default monospace
    fonts.packages = with pkgs; [ nerd-fonts.jetbrains-mono ];
    fonts.fontconfig.enable = true;

    # Nerd font for TTY
    services.kmscon = {
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

    # Sops
    sops = {
      defaultSopsFile = ./../../../../../usr/secrets/passwd.yaml;
      age = {
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = true;
      };
      secrets.default-pass = {
        mode = "0440";
        inherit (config.users.users.nobody) group;
      };
    };

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
