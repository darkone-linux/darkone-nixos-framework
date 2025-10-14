# Full NAS with 3 nvme disks, RAID0, BTRFS + EXT4 (WIP)
#
# TODO: VMI
#
# /dev/nvme0n1 (8TB)
# ├── /boot (EFI, 1GB, vfat)
# ├── BTRFS (reste ~3.97TB)
# ├   ├── subvol=@persist      → /persist (compress=zstd:1)
# ├   ├── subvol=@databases    → /persist/databases (nodatacow)
# ├   ├── subvol=@nix          → /nix (compress=no)
# ├   └── subvol=@snapshots    → /persist/.snapshots
# └── swap (32GB, chiffré)
#
# /dev/nvme1n1 + /dev/nvme2n1 (8TB + 8TB RAID0)
# └── ext4 → /persist/medias (noatime, writeback)
#
# /dev/sda (20TB USB)
# └── ext4 → /persist/backup/local (noatime, automount)
#
# tmpfs → / (8GB)
#

{
  disko.devices = {
    disk = {

      # NVME1 - Main disk
      main = {
        type = "disk";
        device = "/dev/sda";
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

            # Persistant data (impermanence)
            persist = {
              size = "100%";
              end = "-2G";
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ]; # Force overwrite
                subvolumes = {
                  "@persist" = {
                    mountpoint = "/persist";
                    mountOptions = [
                      "subvol=persist"
                      "compress=zstd:1"
                      "noatime"
                      "space_cache=v2"
                    ];
                  };
                  "@databases" = {
                    mountpoint = "/persist/databases";
                    mountOptions = [
                      "subvol=databases"
                      "nodatacow"
                      "noatime"
                    ];
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=no"
                      "noatime"
                      "space_cache=v2"
                    ];
                  };
                  "@snapshots" = { };
                };
              };
            };
            swap = {
              size = "2G";
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
        device = "/dev/sdb";
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
        device = "/dev/sdc";
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
        device = "/dev/sdd";
        content = {
          type = "gpt";
          partitions = {
            backup = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/persist/backup/local";
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

    # Système racine sur tmpfs
    nodev = {
      "/" = {
        fsType = "tmpfs";
        mountOptions = [
          "defaults"
          "size=4G"
          "mode=755"
        ];
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
          mountpoint = "/persist/medias";
        };
      };
    };
  };
}
