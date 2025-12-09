# Media library management system for obsessive music geeks.
#
# :::tips
# Beets service is hosted by "common-files" user.
# ```sh
# su - common-files
# beets import [dir]
# ```
# :::

{
  lib,
  config,
  pkgs,
  zone,
  ...
}:
let
  cfg = config.darkone.service.beets;
  inherit (config.darkone.system) dirs; # Read only
in
{
  options = {
    darkone.service.beets.enable = lib.mkEnableOption "Enable beets for common-files";
    darkone.service.beets.enableService = lib.mkEnableOption "Enable beets service (incoming music -> shared music dir)";
  };

  config = lib.mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Prerequisites
    #--------------------------------------------------------------------------

    # Enable shared music dir and common-files account
    darkone.system.dirs.enableMusic = true;
    darkone.system.dirs.enableIncoming = true;
    darkone.system.dirs.enableIncomingMusic = true;

    # Common-files user beets integration
    home-manager.users.common-files = {

      # ZSH minimal configuration
      imports = [ ./../../../home/profiles/minimal/zsh.nix ];

      # Useful umask for beet program
      programs.zsh = {
        enable = true;
        initContent = ''
          umask 007
        '';
      };

      # Default state version
      home.stateVersion = lib.mkDefault "25.11";
      home.language.base = zone.locale;

      home.packages = with pkgs; [
        chromaprint # Requis pour le fingerprinting acoustique
      ];

      #------------------------------------------------------------------------
      # Beets configuration
      #------------------------------------------------------------------------

      # https://beets.readthedocs.io/en/stable/reference/config.html
      programs.beets = {
        enable = true;
        settings = {
          directory = dirs.music;
          import = {
            write = true;
            copy = true;
            move = false;
            link = false;
            hardlink = false;
            reflink = false;
            resume = true;
            incremental = true;
            quiet = false;
            none_rec_action = "ask";
            timid = false;
            log = "/home/common-files/beets.log";
            group_albums = true;
            duplicate_action = "merge";
            from_scratch = true;
          };

          # To optimize music files matching
          # https://beets.readthedocs.io/en/stable/reference/config.html#autotagger-matching-options
          match = {

            # 0.04 est la valeur minimale acceptée par beets pour un "strong" recommendation
            # Tout ce qui est en dessous est considéré comme strong automatiquement
            strong_rec_thresh = 0.50;

            # 0.0 = il n’y a plus de seuil "medium", même une recommendation très faible devient "medium"
            #medium_rec_thresh = 1.0;

            # Distance maximale autorisée (en moyenne de similarité des titres + autres critères)
            # 1.0 = on accepte même si tout est complètement différent
            #distance = 1.0;
            #max_rec_gap = 0.90;

            # Seuil maximal pour la pénalité de longueur des pistes
            # 1.0 = on ignore complètement les différences de durée (même 10 min d’écart)
            #track_length_grace = 1.0;

            ignored = [
              "missing_tracks"
              "unmatched_tracks"
              "track_length"
            ];
          };

          path = {
            default = "$albumartist/$album%aunique{}/$track $title";
            singleton = "Artists/$artist/$title";
            comp = "Compilations/$album%aunique{}/$track $title";
          };

          plugins = "fetchart embedart chroma fromfilename";
          # plugins = "fetchart embedart duplicates scrub chroma"; # fromfilename

          # 🎨 Configuration du téléchargement de pochettes
          fetchart = {
            auto = true; # Télécharger automatiquement lors de l'import
            cautious = true; # Haute qualité uniquement
            cover_names = "cover front album folder"; # Noms à chercher
            minwidth = 500; # Taille minimale 500px
            maxwidth = 0; # Pas de limite (0 = illimité)
            quality = 0; # Qualité JPEG maximale
            sources = "filesystem coverart itunes amazon albumart";
          };

          # 📦 Intégrer les pochettes dans les fichiers audio
          embedart = {
            auto = true; # Intégrer automatiquement
            ifempty = false; # Remplacer les pochettes existantes
            maxwidth = 0; # Pas de redimensionnement
            quality = 0; # Qualité maximale
          };

          # # Détection doublons
          # duplicates = {
          #   checksum = "ffmpeg";
          # };

          # # Nettoyage métadonnées
          # scrub = {
          #   auto = true;
          # };

          # 🔍 Fingerprinting acoustique (nécessite chromaprint)
          chroma = {
            auto = true; # Utiliser automatiquement si tags normaux échouent
          };

          # 📝 Détection depuis les noms de fichiers
          fromfilename = {
            # Pas de configuration spéciale nécessaire
            # Active automatiquement quand les autres méthodes échouent
          };
        };
      };

      #------------------------------------------------------------------------
      # Beets service
      #------------------------------------------------------------------------
      # With common-files user
      # systemctl --user status beets-import.timer
      # systemctl --user list-timers
      # journalctl --user -u beets-import -f

      # Service systemd pour l'import beets
      systemd.user.services.beets-import = lib.mkIf cfg.enableService {
        Unit = {
          Description = "Automatic media import with Beets";
          After = [ "network.target" ];
        };

        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.beets}/bin/beet import -q ${dirs.incomingMusic}";

          # Variables d'environnement si nécessaire
          # Environment = "BEETSDIR=/home/common-files/.config/beets";

          # Rediriger les logs
          StandardOutput = "journal";
          StandardError = "journal";
        };
      };

      # Timer pour exécuter le service régulièrement
      systemd.user.timers.beets-import = lib.mkIf cfg.enableService {
        Unit = {
          Description = "Timer for automatic Beets import";
        };

        Timer = {

          # Exécuter toutes les heures
          OnCalendar = "hourly";

          # Alternative: toutes les 30 minutes
          # OnCalendar = "*:0/30";

          # Alternative: tous les jours à 2h du matin
          # OnCalendar = "daily";
          # OnCalendar = "02:00";

          # Démarrer 5 minutes après le boot si manqué
          Persistent = true;

          # Randomiser légèrement l'exécution (évite les pics de charge)
          RandomizedDelaySec = "5min";
        };

        Install = {
          WantedBy = [ "timers.target" ];
        };
      };

      # Activer automatiquement le timer
      systemd.user.startServices = lib.mkIf cfg.enableService "sd-switch";
    };
  };
}
