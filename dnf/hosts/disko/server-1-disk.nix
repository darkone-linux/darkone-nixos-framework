# Full server with 3 nvme disks, RAID0, BTRFS + EXT4
#
# /dev/nvme0n1
# ├── /boot (EFI, 1GB, vfat)
# ├── BTRFS
# ├   ├── subvol=@system    → /              (compress=zstd:1)
# ├   ├── subvol=@nix       → /nix           (compress=zstd:1)
# ├   ├── subvol=@home      → /home          (compress=zstd:1)
# ├   ├── subvol=@media     → /mnt/media     (compress=zstd:1)
# ├   ├── subvol=@backup    → /mnt/backup    (compress=no)
# ├   ├── subvol=@databases → /mnt/databases (nodatacow,compress=no)
# ├   ├── subvol=@snapshots-home
# ├   ├── subvol=@snapshots-system
# ├   └── subvol=@snapshots-databases
# └── swap (4GB)
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

                  # Media files (compressed, not snapshotted)
                  "@media" = {
                    mountpoint = "/mnt/media";
                    mountOptions = [
                      "compress=zstd:1"
                      "noatime"
                    ];
                  };

                  # Backup files (not compressed - already compressed by backup tool, not snapshotted)
                  "@backup" = {
                    mountpoint = "/mnt/backup";
                    mountOptions = [
                      "compress=no"
                      "noatime"
                    ];
                  };

                  # Databases files (nodatacow, not compressed)
                  "@databases" = {
                    mountpoint = "/mnt/databases";
                    mountOptions = [
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
              size = "4G";
              content = {
                type = "swap";
                randomEncryption = false;
              };
            };
          };
        };
      };
    };
  };
}
