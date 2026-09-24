# Simple machine with 1 disk, EXT4, LEGACY (BIOS/CSM only, no swap)
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
            bios = {
              size = "1M";
              type = "EF02";
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
