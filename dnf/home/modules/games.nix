# Several graphical game packages.

{
  pkgs,
  pkgs-stable,
  lib,
  config,
  osConfig,
  ...
}:
let
  cfg = config.darkone.home.games;

  # Conditions
  isBabyOrChild = cfg.enableBaby || cfg.enableChild;
  isChildOrTeen = cfg.enableChild || cfg.enableTeenager;
  isNotBaby = !cfg.enableBaby;
  g3d = cfg.enable3D && isChildOrTeen;
  cli = isNotBaby && cfg.enableCli;
  moreCli = cfg.enableMore && cli;
  stk = isChildOrTeen || cfg.enableStk;

  # STK
  hasStkShare = stk && osConfig.darkone.graphic.supertuxkart.enable;
  isStkServer = osConfig.darkone.graphic.supertuxkart.isNfsServer;
  stkSharePrefix = if isStkServer then osConfig.darkone.system.srv-dirs.nfs else "/mnt/nfs";
in
{
  options = {
    darkone.home.games.enable = lib.mkEnableOption "Enable games";
    darkone.home.games.enableBaby = lib.mkEnableOption "Games for babies (<=6 yo)";
    darkone.home.games.enableChild = lib.mkEnableOption "Games for children (6-12 yo)";
    darkone.home.games.enableTeenager = lib.mkEnableOption "Games for teenagers and adults (>=12 yo)";
    darkone.home.games.enable3D = lib.mkEnableOption "More 3D Games";
    darkone.home.games.enableCli = lib.mkEnableOption "Cli Games";
    darkone.home.games.enableStk = lib.mkEnableOption "SuperTuxKart (only)";
    darkone.home.games.enableMore = lib.mkEnableOption "More (secondary) games in each categories";
    darkone.home.games.stkServer = lib.mkOption {
      type = lib.types.str;
      default = osConfig.darkone.service.nfs.serverDomain;
      description = "STK server domain name";
    };
  };

  config = lib.mkIf (cfg.enableBaby || cfg.enableChild || cfg.enableTeenager) {

    #--------------------------------------------------------------------------
    # Packages
    #--------------------------------------------------------------------------

    # NOTE banned games: bsdgames, 2048 terminal, ltris, lenmus, chessx, kanagram, pingus
    home.packages = with pkgs; [
      (lib.mkIf cli sssnake)
      (lib.mkIf cli tetris)
      (lib.mkIf g3d veloren) # Minecraft like
      (lib.mkIf isBabyOrChild kdePackages.ktuberling) # Constructor game
      (lib.mkIf isBabyOrChild rili) # train game
      (lib.mkIf isBabyOrChild tuxpaint)
      (lib.mkIf isChildOrTeen atomix) # Atom puzzle
      (lib.mkIf isChildOrTeen chess-clock)
      (lib.mkIf isChildOrTeen cuyo) # Tetris like
      (lib.mkIf isChildOrTeen gnome-solanum) # Pomodoro timer
      (lib.mkIf isChildOrTeen gnome-sudoku)
      (lib.mkIf isChildOrTeen kdePackages.kbounce) # Bal game
      (lib.mkIf isChildOrTeen kdePackages.kpat) # Solitaire games
      (lib.mkIf isChildOrTeen kdePackages.picmi) # Logical game
      (lib.mkIf isChildOrTeen leocad) # Virt lego
      (lib.mkIf isChildOrTeen pkgs-stable.gnome-2048)
      (lib.mkIf isNotBaby gnome-chess)
      (lib.mkIf isNotBaby gnome-mahjongg)
      (lib.mkIf isNotBaby gnome-mines)
      (lib.mkIf isNotBaby gnuchess) # Chess engine for gnome-chess
      (lib.mkIf isNotBaby stockfish) # Chess engine for gnome-chess
      (lib.mkIf moreCli chess-tui)
      (lib.mkIf moreCli crawl) # role-playing roguelike game
      (lib.mkIf moreCli nethack) # Rogue-like game
      (lib.mkIf moreCli solitaire-tui)
      (lib.mkIf stk superTuxKart)
    ];

    #--------------------------------------------------------------------------
    # STK
    #--------------------------------------------------------------------------

    # Unlock STK
    # Exécuté après l'écriture des fichiers de conf par HM (writeBoundary)
    home.activation = lib.mkIf stk {
      unlockSupertuxkart = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        configPath="${config.home.homeDirectory}/.config/supertuxkart/config-0.10"
        configFile="$configPath/config.xml"
        if [ -f "$configFile" ]; then
          ${pkgs.gnused}/bin/sed -i 's/<unlock_everything value="[^"]*"/<unlock_everything value="2"/' "$configFile"
          echo "[STK] config file exists, unlock_everything set to 2"
        else
          echo "[STK] config file not found, write the snippet..."
          mkdir -p "$configPath"
          echo '<?xml version="1.0"?><stkconfig version="8"><Video fullscreen="true" /><unlock_everything value="2" /></stkconfig>' > "$configFile"
        fi
      '';
    };

    # STK link to shared tracks
    systemd.user.tmpfiles.rules = lib.mkIf hasStkShare [
      "d ${config.home.homeDirectory}/.local/share/supertuxkart/addons 0755 ${config.home.username} users -"
      "L+ ${config.home.homeDirectory}/.local/share/supertuxkart/addons/tracks - - - - ${stkSharePrefix}/stk-tracks"
    ];
  };
}
