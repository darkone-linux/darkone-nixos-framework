# Printers and scanners.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.printing;
  all-users = builtins.attrNames config.users.users;
  normal-users = builtins.filter (user: config.users.users.${user}.isNormalUser) all-users;
in
{
  options = {
    darkone.service.printing.enable = lib.mkEnableOption "Default useful packages";
    darkone.service.printing.loadAll = lib.mkEnableOption "Full printers and scanners";
    darkone.service.printing.enableScanners = lib.mkEnableOption "Enable scanners";
    darkone.service.printing.enableHpPrinters = lib.mkEnableOption "HP printers only";
    darkone.service.printing.enableManualInstall = lib.mkEnableOption "Manual drivers installation";
  };

  config = lib.mkIf cfg.enable {

    # Printing service configuration
    services.printing = {
      enable = true;
      startWhenNeeded = true;
      drivers =
        with pkgs;
        (
          if cfg.loadAll then
            [
              brgenml1cupswrapper
              brgenml1lpr
              brlaser
              cnijfilter2
              epkowa
              gutenprint
              gutenprintBin
              samsung-unified-linux-driver
              splix
            ]
          else
            [ ]
        )
        ++ (
          if cfg.loadAll || cfg.enableHpPrinters then
            [
              hplip
              hplipWithPlugin
            ]
          else
            [ ]
        );
    };

    # To install printers manually
    programs.system-config-printer = lib.mkIf cfg.enableManualInstall { enable = true; };

    # Enable autodiscovery
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    # Who can print?
    users.groups.lp = {
      members = normal-users;
    };

    # systemd.services.cups-browsed.enable = false;
    hardware.sane = lib.mkIf cfg.enableScanners {
      enable = true;
      extraBackends = with pkgs; [
        hplipWithPlugin
        sane-airscan
        epkowa
        utsushi
      ];
    };
    services.udev.packages = lib.mkIf cfg.enableScanners [
      pkgs.sane-airscan
      pkgs.utsushi
    ];

    # add all users to group scanner and lp
    users.groups.scanner = lib.mkIf cfg.enableScanners { members = normal-users; };
  };
}
