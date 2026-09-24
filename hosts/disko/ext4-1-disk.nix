# Simple machine with 1 disk, EXT4
# Disk paths: tokens replaced from `disko.devices` of etc/config.yaml.

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "@DEVICE:main@";
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

            # MAIN
            root = {
              end = "-4G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };

            # Non encrypted swap
            swap = {
              size = "100%";
              content = {
                type = "swap";
                discardPolicy = "both";
                resumeDevice = true; # resume from hiberation from this device
              };
            };
          };
        };
      };
    };
  };
}
