# Fail2ban DNF specific module.

{ config, lib, ... }:
let
  cfg = config.darkone.service.fail2ban;
in
{
  options = {
    darkone.service.fail2ban.enable = lib.mkEnableOption "Enable fail2ban with DNF specificities";
  };

  config = lib.mkIf cfg.enable {

    # Improved Fail2ban for Gateways and HCS
    services.fail2ban = {
      enable = true;
      maxretry = 1;
      bantime = "24h"; # Ban IPs for one day on the first ban
      bantime-increment = {
        enable = true; # Enable increment of bantime after each violation
        multipliers = "1 2 4 8 16 32 64";
        maxtime = "1w"; # Do not ban for more than 1 week
        overalljails = true; # Calculate the bantime based on all the violations
      };
      ignoreIP = [
        "10.0.0.0/8"
        "100.64.0.0/10"
      ];
    };
  };
}
