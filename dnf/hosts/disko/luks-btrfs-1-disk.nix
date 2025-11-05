# Simple machine with 1 disk, BTRFS
# Ex: https://github.com/nix-community/disko/blob/master/example/luks-btrfs-subvolumes.nix

{
  disko.devices = {
    disk = {
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

            luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "crypted";
                settings = {
                  allowDiscards = true;
                };
                content = {
                  type = "btrfs";
                  extraArgs = [ "-f" ];
                  subvolumes = {

                    # System partition
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
                        "compress=zstd:3" # More compression, only for fast CPUs
                        "noatime"
                        "metadata_ratio=3" # More space for metadata (lot of little files)
                      ];
                    };

                    # Home files from home directories (little files, compressed, snapshotted)
                    "@home" = {
                      mountpoint = "/home";
                      mountOptions = [
                        "compress=zstd:1"
                        "noatime"
                      ];
                    };

                    "@swap" = {
                      mountpoint = "/.swapfile";
                      swap.swapfile.size = "1G";
                    };

                    # Snapshots (not mounted)
                    "@snapshots-home" = { };
                    "@snapshots-system" = { };
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
