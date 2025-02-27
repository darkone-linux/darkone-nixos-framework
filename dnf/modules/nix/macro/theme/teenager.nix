# Features for teenagers.

{ lib, config, ... }:
let
  cfg = config.darkone.theme.teenager;
in
{
  options = {
    darkone.theme.teenager.enable = lib.mkEnableOption "Teenager softwares";
  };

  config = lib.mkIf cfg.enable {

    # Additional features for teens
    darkone.graphic.education.enable = lib.mkDefault true;
    darkone.graphic.education.enableTeenager = lib.mkDefault true;
    darkone.graphic.education.enableGames = lib.mkDefault true;
  };
}
