{
  lib,
  config,
  host,
  pkgs,
  ...
}:
let
  cfg = config.darkone.system.core;
in
{
  options = {
    darkone.system.core.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Darkone framework core system (activated by default)";
    };
    darkone.system.core.enableFstrim = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = "SSD optimisation with fstrim";
    };
    darkone.system.core.enableFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = "Enable firewall (default true)";
    };
    darkone.system.core.enableBoost = lib.mkEnableOption "Enable overclocking, corectl";
  };

  # Useful man & nix documentation
  config = lib.mkIf cfg.enable {

    # Bootloader
    boot = {
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
    # TODO: use global configuration for keyboard layout
    services.kmscon = {
      enable = true;
      fonts = [
        {
          name = "JetBrainsMono Nerd Font Mono";
          package = pkgs.nerd-fonts.jetbrains-mono;
        }
      ];
      extraOptions = "--term xterm-256color";
      extraConfig = ''
        font-size=14
        xkb-layout=fr
      '';
    };

    # To manage nodes, openssh must be activated
    services.openssh.enable = true;

    # Disks checking / monitoring
    # https://doc.ubuntu-fr.org/smartmontools
    services.smartd = {
      enable = false;
      autodetect = true;
    };

    # Write installed packages in /etc/installed-packages
    environment.etc."installed-packages".text =
      let
        packages = builtins.map (p: "${p.name}") config.environment.systemPackages;
        sortedUnique = builtins.sort builtins.lessThan (pkgs.lib.lists.unique packages);
        formatted = builtins.concatStringsSep "\n" sortedUnique;
      in
      formatted;

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
  };
}
