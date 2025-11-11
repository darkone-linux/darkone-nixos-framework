# Several graphical game packages.

{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.darkone.home.games;
in
{
  options = {
    darkone.home.games.enableBaby = lib.mkEnableOption "Games for babies (<=6 yo)";
    darkone.home.games.enableChild = lib.mkEnableOption "Games for children (6-12 yo)";
    darkone.home.games.enableTeenager = lib.mkEnableOption "Games for teenagers and adults (>=12 yo)";
    darkone.home.games.enable3D = lib.mkEnableOption "More 3D Games";
  };

  config = lib.mkIf (cfg.enableBaby || cfg.enableChild || cfg.enableTeenager) {

    # Packages
    home.packages = with pkgs; [
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) chessx)
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) endless-sky) # Sandbox-style space exploration game
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) lenmus) # LenMus Phonascus is a program for learning music
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) leocad) # Virt lego
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) cuyo) # Tetris like
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) superTuxKart)
      (lib.mkIf (cfg.enable3D && (cfg.enableChild || cfg.enableTeenager)) veloren) # Minecraft like
      (lib.mkIf (cfg.enableBaby || cfg.enableChild) rili) # train game
      (lib.mkIf (cfg.enableBaby || cfg.enableChild) tuxpaint)
      (lib.mkIf cfg.enableChild pingus)
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) atomix) # Atom puzzle
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) chess-clock)
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) gnome-mahjongg)
    ];

    # Unlock STK
    home.activation = lib.mkIf (cfg.enableChild || cfg.enableTeenager) {
      unlockSupertuxkart = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        config_file="$HOME/.config/supertuxkart/config-0.10/config.xml"
        if [ -f "$config_file" ]; then
          ${pkgs.gnused}/bin/sed -i \
            's/<unlock_everything value="[^"]*"/<unlock_everything value="2"/' \
            "$config_file"
          echo "SuperTuxKart unlock_everything set to 2"
        fi
      '';
    };
  };
}
