# Virtual machine with impermanence, BTRFS + TMPFS

{
  disko.devices = {
    disk = {

      # A "main" disk is required (dnf)
      main = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {

            # EFI
            boot = {
              size = "500M";
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

            # This disk must be named "persist" to indicate installer to use impermanence!
            persist = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ]; # Force overwrite
                subvolumes = {

                  # Common persistant system and other files (little files, compressed, snapshotted)
                  "@system" = {
                    mountpoint = "/persist/system";
                    mountOptions = [
                      "compress=zstd:1"
                      "noatime"
                    ];
                  };

                  # Home files from home directories (little files, compressed, snapshotted)
                  "@home" = {
                    mountpoint = "/persist/home";
                    mountOptions = [
                      "compress=zstd:1"
                      "noatime"
                    ];
                  };

                  # Databases (nocow, not compressed, snapshotted)
                  "@databases" = {
                    mountpoint = "/persist/databases";
                    mountOptions = [
                      "nodatacow"
                      "noatime"
                    ];
                  };

                  # Medias, images, movies & big files (nocow, not compressed, not snapshotted)
                  # This partition is intended to be on a different physical disk in principle
                  "@medias" = {
                    mountpoint = "/persist/medias";
                    mountOptions = [
                      "nodatacow"
                      "noatime"
                    ];
                  };

                  # Backup directory for borg (compressed, not snapshotted)
                  # This folder should be reserved for backup mount points
                  # /persist/backup/<location>
                  "@backup" = {
                    mountpoint = "/persist/backup";
                    mountOptions = [
                      "compress=zstd:1"
                      "noatime"
                    ];
                  };

                  # Nix store (compressed, not declared in impermanence)
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=no"
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
          };
        };
      };
    };

    # Root system on tmpfs
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
  };
}
