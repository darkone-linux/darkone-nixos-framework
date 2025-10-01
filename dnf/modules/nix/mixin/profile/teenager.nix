# Features for teenagers.

{ lib, config, ... }:
let
  cfg = config.darkone.profile.teenager;
in
{
  options = {
    darkone.profile.teenager.enable = lib.mkEnableOption "Teenager softwares";
  };

  config = lib.mkIf cfg.enable {

    # Additional features for teens
    darkone.graphic.education.enable = lib.mkDefault true;
    darkone.graphic.education.enableTeenager = lib.mkDefault true;
    darkone.graphic.games.enable = lib.mkDefault true;
  };
}
