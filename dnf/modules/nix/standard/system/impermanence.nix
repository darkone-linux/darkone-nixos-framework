# Impermanance management module (used by others).
#
# :::caution[DNF impermanence rules]
# - `/persist/home` contains files from homes (btrfs+zstd)
# - `/persist/system` contains system and other files (btrfs+zstd)
# - `/persist/databases` contains database files (btrfs+nocow)
# - `/persist/medias` contains images, videos and big files (ext4 or btrfs+nocow)
# - `/persist/backup/<location>` contains backup files (ext4/xfs)
# :::

# TODO: clarifier

{
  lib,
  config,
  host,
  ...
}:
with lib;
let
  cfg = config.darkone.system.impermanence;

  # TODO: xdg.userDirs...
  # userDirs = {
  #   desktop = "Desktop";
  #   documents = "Documents";
  #   music = "Music";
  #   pictures = "Pictures";
  #   videos = "Videos";
  #   download = "Downloads";
  # };

in
{
  options.darkone.system.impermanence = {

    # Enable impermanence module
    enable = mkEnableOption "Enable impermanence DNF mechanism";

    # Additional dirs in /persist/system
    extraPersistDirs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/var/lib/immich" ];
      description = "Extra regular persistant dirs";
    };

    extraPersistFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra regular persistant files";
    };

    # Additional dirs in /persist/databases
    extraDbPersistDirs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "/var/lib/postgresql"
        "/var/lib/docker"
      ];
      description = "Extra database persistant dirs";
    };

    extraDbPersistFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra database persistant files";
    };

    # Additional dirs in /persist/medias
    extraMediaPersistDirs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "/var/lib/immich/encoded-video"
        "/var/lib/immich/library"
        "/var/lib/immich/upload"
      ];
      description = "Extra media persistant dirs";
    };

    # Backup locations configuration
    backupLocations = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            directories = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Directories to persist in this backup location";
            };
            files = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Files to persist in this backup location";
            };
          };
        }
      );
      default = { };
      example = {
        nfs1 = {
          directories = [ "/var/backups/daily" ];
          files = [ "/var/backups/backup.log" ];
        };
        usbDisk = {
          directories = [ "/var/backups/weekly" ];
        };
      };
      description = "Backup locations and their persistent data";
    };

    # Users configuration
    usersPersistDirs = mkOption {
      type = types.listOf (types.either types.str (types.attrsOf types.str));
      default = [

        # TODO: from xdg.userDirs...
        # userDirs.desktop
        # userDirs.documents
        # userDirs.music
        # userDirs.pictures
        # userDirs.videos
        # userDirs.download

        # TMP, TODO: subfolders that depends on each app
        # /!\ ACTIVATE .config is a BAD IDEA, .config contains impermanence activation services for home manager /!\
        #".config/<xxx>"

        ".ssh"
        ".gnupg"
        ".local/share"
        ".local/state/nix"
      ];
      example = [
        ".ssh"
        ".gnupg"
        ".local/share"
        ".local/state/nix"
        "Desktop"
        "Documents"
        "Music"
        "Pictures"
        "Videos"
        "Downloads"
        {
          directory = ".local/share/Steam";
          method = "symlink";
        }
      ];
      description = "Default directories to persist for all users";
    };

    usersPersistFiles = mkOption {
      type = types.listOf types.str;
      default = [ ]; # [ ".zshrc" ];
      description = "Default files to persist for all users";
    };
  };

  # Impermanence DNF config
  config = mkIf cfg.enable {

    # Required filesystems for boot
    fileSystems = {
      "/nix".neededForBoot = true;
      "/boot".neededForBoot = true;
      "/persist/home".neededForBoot = true;
      "/persist/system".neededForBoot = true;
      "/persist/medias".neededForBoot = true;
      "/persist/databases".neededForBoot = true;
    };

    # Lastlog service access to its db
    systemd.tmpfiles.rules = [
      "d /var/lib/lastlog 0775 root utmp -"
      "d /persist/home 0775 root users -"
    ];

    # Home manager allowOther
    programs.fuse.userAllowOther = true;

    # etc + persistance
    environment.persistence = {

      # Persist common dir for various data (btrfs+zstd) /persist/system
      "/persist/system" = {
        hideMounts = true;
        directories = [
          "/var/log"
          "/var/lib/nixos"
          "/var/lib/systemd"
          "/var/lib/lastlog"
        ]
        ++ cfg.extraPersistDirs;
        files = [
          "/etc/machine-id"
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_ed25519_key.pub"
          "/etc/ssh/ssh_host_rsa_key"
          "/etc/ssh/ssh_host_rsa_key.pub"
        ]
        ++ cfg.extraPersistFiles;
      };

      # Medias persist dir (btrfs nocompress or ext4 or xfs)  /persist/medias
      "/persist/medias" = {
        hideMounts = true;
        directories = cfg.extraMediaPersistDirs;
      };

      # Databases persist dir (btrfs+nocow) /persist/databases
      "/persist/databases" = {
        hideMounts = true;
        directories = cfg.extraDbPersistDirs;
        files = cfg.extraDbPersistFiles;
      };
    }
    // mapAttrs' (

      # Backup locations (ext4 or xfs) /persist/backup
      location: locConfig:
      nameValuePair "/persist/backup/${location}" {
        hideMounts = true;
        inherit (locConfig) directories;
        inherit (locConfig) files;
      }
    ) cfg.backupLocations;

    # Users home directories (home manager)
    home-manager.users = genAttrs host.users (name: {
      home.persistence."/persist/home/${name}" = {
        directories = cfg.usersPersistDirs;
        files = cfg.usersPersistFiles;
        allowOther = true;
      };
    });
  };
}
