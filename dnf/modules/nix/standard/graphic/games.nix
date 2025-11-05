# Several graphical game packages.
#
# :::note
# These programs are installed for all user profiles.
# Use HomeManager profiles to provide software tailored to each user (admin, advanced, student, child, teenager, etc.).
# :::

# TODO: home-manager module
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.games;
in
{
  options = {
    darkone.graphic.games.enable = lib.mkEnableOption "Enable game packages (please select age group)";
    darkone.graphic.games.enableBaby = lib.mkEnableOption "Games for babies (<=6 yo)";
    darkone.graphic.games.enableChildren = lib.mkEnableOption "Games for children (6-12 yo)";
    darkone.graphic.games.enableTeenager = lib.mkEnableOption "Games for teenagers and adults (>=12 yo)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      with pkgs;
      (
        # (lib.mkIf cfg.enableChildren childsplay) # Not found
        # (lib.mkIf cfg.enableChildren tuxblocs) # Not found
        (lib.mkIf (cfg.enableChildren || cfg.enableTeenager) chessx)
          (lib.mkIf (cfg.enableChildren || cfg.enableTeenager) endless-sky) # Sandbox-style space exploration game
          (lib.mkIf (cfg.enableChildren || cfg.enableTeenager) lenmus) # LenMus Phonascus is a program for learning music
          (lib.mkIf (cfg.enableChildren || cfg.enableTeenager) leocad)
          (lib.mkIf (cfg.enableChildren || cfg.enableTeenager) supertuxkart)
          (lib.mkIf cfg.enableBaby rili)
          (lib.mkIf cfg.enableChildren pingus)
          (lib.mkIf cfg.enableTeenager veloren)
      );
  };
}
