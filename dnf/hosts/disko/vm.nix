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
                  "/system" = {
                    mountpoint = "/";
                    mountOptions = [
                      "subvol=system"
                      "compress=zstd:1"
                      "noatime"
                      "space_cache=v2"
                    ];
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=no"
                      "noatime"
                      "space_cache=v2"
                    ];
                  };
                  "/snapshots" = { };
                };
              };
            };
          };
        };
      };
    };
  };
}
