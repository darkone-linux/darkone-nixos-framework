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
  enableStk = cfg.enableChild || cfg.enableTeenager || cfg.enableStk;
  enableStkShare = enableStk && osConfig.darkone.graphic.supertuxkart.enable;
  isStkServer = osConfig.darkone.graphic.supertuxkart.isNfsServer;
  stkSharePrefix = if isStkServer then osConfig.darkone.system.srv-dirs.nfs else "/mnt/nfs";
in
{
  options = {
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

    home.packages = with pkgs; [
      #(lib.mkIf cfg.enableChild pingus) # Bugged
      (lib.mkIf (cfg.enable3D && (cfg.enableChild || cfg.enableTeenager)) veloren) # Minecraft like
      (lib.mkIf (cfg.enableBaby || cfg.enableChild) rili) # train game
      (lib.mkIf (cfg.enableBaby || cfg.enableChild) tuxpaint)
      (lib.mkIf (cfg.enableBaby || cfg.enableChild) kdePackages.ktuberling) # Constructor game
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) kdePackages.kpat) # Solitaire games
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) kdePackages.kbounce) # Bal game
      #(lib.mkIf (cfg.enableChild || cfg.enableTeenager) kdePackages.kanagram)
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) kdePackages.picmi) # Logical game
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) atomix) # Atom puzzle
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) chess-clock)
      #(lib.mkIf (cfg.enableChild || cfg.enableTeenager) chessx) # write in ~/Documents
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) cuyo) # Tetris like
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) pkgs-stable.gnome-2048)
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) gnome-chess)
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) gnuchess) # Chess engine for gnome-chess
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) stockfish) # Chess engine for gnome-chess
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) gnome-mahjongg)
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) gnome-mines)
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) gnome-solanum) # Pomodoro timer
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) gnome-sudoku)
      #(lib.mkIf (cfg.enableChild || cfg.enableTeenager) lenmus) # LenMus Phonascus is a program for learning music (vieillot)
      (lib.mkIf (cfg.enableChild || cfg.enableTeenager) leocad) # Virt lego
      #(lib.mkIf (cfg.enableChild || cfg.enableTeenager) ltris) # Tetris (bof)
      #(lib.mkIf (cfg.enableMore && cfg.enableCli) _2048-in-terminal)
      #(lib.mkIf (cfg.enableMore && cfg.enableCli) bsdgames)
      (lib.mkIf (cfg.enableMore && cfg.enableCli) chess-tui)
      (lib.mkIf (cfg.enableMore && cfg.enableCli) crawl) # role-playing roguelike game
      (lib.mkIf (cfg.enableMore && cfg.enableCli) nethack) # Rogue-like game
      (lib.mkIf (cfg.enableMore && cfg.enableCli) solitaire-tui)
      (lib.mkIf cfg.enableCli sssnake)
      (lib.mkIf cfg.enableCli tetris)
      (lib.mkIf cfg.enableStk superTuxKart)
    ];

    #--------------------------------------------------------------------------
    # STK
    #--------------------------------------------------------------------------

    # Unlock STK
    # Exécuté après l'écriture des fichiers de conf par HM (writeBoundary)
    home.activation = lib.mkIf enableStk {
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
    systemd.user.tmpfiles.rules = lib.mkIf enableStkShare [
      "d ${config.home.homeDirectory}/.local/share/supertuxkart/addons 0755 ${config.home.username} users -"
      "L+ ${config.home.homeDirectory}/.local/share/supertuxkart/addons/tracks - - - - ${stkSharePrefix}/stk-tracks"
    ];
  };
}
