# Full server with 3 nvme disks, RAID0, BTRFS + EXT4
#
# /dev/nvme0n1 (8TB)
# ├── /boot (EFI, 1GB, vfat)
# ├── BTRFS (reste ~7.97TB)
# ├   ├── subvol=@system    → /              (compress=zstd:1)
# ├   ├── subvol=@nix       → /nix           (compress=no)
# ├   ├── subvol=@home      → /home          (compress=zstd:1)
# ├   ├── subvol=@databases → /mnt/databases (nodatacow,compress=no)
# ├   ├── subvol=@snapshots-home
# ├   ├── subvol=@snapshots-system
# ├   └── subvol=@snapshots-databases
# └── swap (32GB, chiffré)
#
# /dev/nvme1n1 + /dev/nvme2n1 (8TB + 8TB RAID0)
# └── ext4 → /mnt/medias (noatime, writeback)
#
# /dev/sda (20TB USB)
# └── ext4 → /mnt/backup (noatime, automount)
#
# Do not remove:
# NEEDEDFORBOOT:/boot;/nix;/home;/mnt/databases;/mnt/medias
#

{
  disko.devices = {
    disk = {

      # NVME1 - Main disk
      main = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {

            # EFI
            boot = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                  "umask=0077"
                ];
              };
            };

            # Main disk
            system = {
              size = "100%";
              end = "-32";
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ]; # Force overwrite
                subvolumes = {

                  # Root partition
                  "@system" = {
                    mountpoint = "/";
                    mountOptions = [
                      "compress=zstd:1"
                      "noatime"
                    ];
                  };

                  # Nix store
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=zstd:1"
                      "noatime"
                    ];
                  };

                  # Files from home directories (little files, compressed, snapshotted)
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = [
                      "compress=zstd:1"
                      "noatime"
                    ];
                  };

                  # Databases files (nodatacow, not compressed)
                  "@databases" = {
                    mountpoint = "/mnt/databases";
                    mountOptions = [
                      "subvol=databases"
                      "nodatacow"
                      "noatime"
                    ];
                  };

                  # Snapshots (not mounted)
                  "@snapshots-home" = { };
                  "@snapshots-system" = { };
                  "@snapshots-databases" = { };
                };
              };
            };
            swap = {
              size = "32G";
              content = {
                type = "swap";
                randomEncryption = false;
              };
            };
          };
        };
      };

      # NVME2 - RAID0
      media1 = {
        type = "disk";
        device = "/dev/nvme1n1";
        content = {
          type = "gpt";
          partitions = {
            raid = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "medias";
              };
            };
          };
        };
      };

      # NVME3 - RAID0
      media2 = {
        type = "disk";
        device = "/dev/nvme2n1";
        content = {
          type = "gpt";
          partitions = {
            raid = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "medias";
              };
            };
          };
        };
      };

      # Disque USB externe (hot-pluggable)
      backup = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            backup = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/backup";
                mountOptions = [
                  "noatime"
                  "data=writeback"
                  "noauto" # Ne pas monter automatiquement au boot
                  "x-systemd.automount" # Montage à la demande
                  "x-systemd.idle-timeout=300" # Démonte après 5min d'inactivité
                ];
              };
            };
          };
        };
      };
    };

    # RAID0
    mdadm = {
      medias = {
        type = "mdadm";
        level = 0;
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/mnt/medias";
        };
      };
    };
  };
}
