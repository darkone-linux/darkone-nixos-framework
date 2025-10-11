# Impermanance management module (used by others).
#
# :::caution[DNF impermanence rules]
# - `/persist` contains regular files (btrfs+zstd)
# - `/persist/databases` contains database files (btrfs+nocow)
# - `/persist/medias` contains images, videos and big files (ext4 or btrfs+nocow)
# - `/persist/backup/<location>` contains backup files (ext4/xfs)
# :::
#
# Recommanded filesystems:
#
# ```nix
# # Fichiers communs
# fileSystems."/persist" = {
#   device = "/dev/disk/by-label/persist";
#   fsType = "btrfs";
#   options = [
#     "subvol=persist"
#     "compress=zstd:1" # Niveau 1 = bon compromis vitesse/ratio
#     "noatime"
#     "space_cache=v2"
#   ];
#   neededForBoot = true;
# };
#
# # Bases de données : subvolume séparé sans compression
# fileSystems."/persist/databases" = {
#   device = "/dev/disk/by-label/persist";
#   fsType = "btrfs";
#   options = [
#     "subvol=databases"
#     "nodatacow"  # Désactive COW pour performance DB
#     "noatime"
#   ];
#   depends = [ "/persist" ];
# };
#
# # Pour /etc/nixos
# fileSystems."/etc/nixos" = {
#   device = "/persist/etc/nixos";
#   options = [ "bind" ];
#   depends = [ "/persist" ];
# };
#
# # Stockage de médias sur disques séparés
# fileSystems."/persist/medias" = {
#   device = "/dev/disk/by-label/medias";
#   fsType = "ext4";
#   options = [
#     "noatime"        # Pas besoin de mettre à jour atime
#     "data=writeback" # Performance maximale (safe pour Borg)
#   ];
# };
#
# # Backup local (disque externe par exemple)
# fileSystems."/persist/backup/local" = {
#   device = "/dev/disk/by-label/usb-disk";
#   fsType = "ext4";
#   options = [
#     "noatime"        # Pas besoin de mettre à jour atime
#     "data=writeback" # Performance maximale (safe pour Borg)
#   ];
# };
# ```

{ lib, config, ... }:
with lib;
let
  cfg = config.darkone.system.impermanence;
  userDirs = {
    desktop = "Desktop";
    documents = "Documents";
    music = "Music";
    pictures = "Pictures";
    videos = "Videos";
    download = "Downloads";
  };
in
{
  options.darkone.system.impermanence = {

    # Enable impermanence module
    enable = mkEnableOption "Enable impermanence DNF mechanism";

    # The persist root directory
    persistRootDir = mkOption {
      type = types.str;
      default = "/persist";
      description = "Root directory for persistent data";
    };

    # Additional dirs in /persist
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
    users = {
      persistDirs = mkOption {
        type = types.listOf (types.either types.str (types.attrsOf types.anything));
        default = [
          userDirs.desktop
          userDirs.documents
          userDirs.music
          userDirs.pictures
          userDirs.videos
          userDirs.download
          ".ssh"
          ".gnupg"
          {
            directory = ".local/share";
            mode = "0700";
          }
          {
            directory = ".config";
            mode = "0700";
          }
          {
            directory = ".thunderbird";
            mode = "0700";
          }
          {
            directory = ".cache";
            mode = "0700";
          }
        ];
        description = "Default directories to persist for all users";
      };

      persistFiles = mkOption {
        type = types.listOf types.str;
        default = [ ".zshrc" ];
        description = "Default files to persist for all users";
      };

      extraUserConfig = mkOption {
        type = types.attrsOf (types.attrsOf types.anything);
        default = { };
        example = {
          alice = {
            directories = [
              "Projects"
              ".config/Code"
            ];
          };
        };
        description = "Extra persistence configuration per user";
      };
    };
  };

  # Impermanence DNF config
  config = mkIf cfg.enable {

    # etc + persistance
    environment.persistence = {

      # Persist root dir (btrfs+zstd)
      "${cfg.persistRootDir}" = {
        hideMounts = true;
        directories = [
          "/var/lib" # TODO: each app need to add its folder + remove this
          "/var/log"
          "/etc/nixos"
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

        # Users
        users = mapAttrs (
          name: _user:
          let
            baseConfig = {
              directories = cfg.users.persistDirs;
              files = cfg.users.persistFiles;
            };
            extraConfig = cfg.users.extraUserConfig.${name} or { };
          in
          recursiveUpdate baseConfig extraConfig
        ) (filterAttrs (_name: user: user.isNormalUser) config.users.users);
      };

      # Databases persist dir (btrfs+nocow)
      "${cfg.persistRootDir}/databases" = {
        hideMounts = true;
        directories = cfg.extraDbPersistDirs;
        files = cfg.extraDbPersistFiles;
      };

      # Medias persist dir (ext4 or xfs)
      "${cfg.persistRootDir}/medias" = {
        hideMounts = true;
        directories = cfg.extraMediaPersistDirs;
      };
    }
    // mapAttrs' (

      # Backup locations (ext4 or xfs)
      location: locConfig:
      nameValuePair "${cfg.persistRootDir}/backup/${location}" {
        hideMounts = true;
        inherit (locConfig) directories;
        inherit (locConfig) files;
      }
    ) cfg.backupLocations;
  };
}
