# Simple virtual machine, BTRFS

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

            system = {
              size = "100%";
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
                      "compress=zstd:1"
                      "noatime"
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
}
