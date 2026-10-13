# Decision table of `modules/service/monitoring/fs-forced-readonly.awk`, pinned.
#
# The parser is the whole `FilesystemReadOnly` signal: a missed line silences a
# failing disk, an extra one pages for an intended `ro` bind. The fixture holds
# one mountinfo line per case, real layouts (btrfs subvolumes, systemd
# credentials, erofs) included.

{ pkgs, ... }:
let

  # Columns: id parent major:minor root mountpoint per-mount-options
  # [optional fields] - fstype source superblock-options.
  mountinfo = builtins.toFile "mountinfo" ''
    24 1 0:22 /@system / rw,noatime shared:1 - btrfs /dev/sda2 rw,compress=zstd:1,subvol=/@system
    30 24 0:30 /@varlib /var/lib rw,noatime shared:2 - btrfs /dev/mapper/data ro,compress=zstd:1,subvol=/@varlib
    31 24 0:30 /@home /home rw,noatime shared:3 - btrfs /dev/mapper/data ro,compress=zstd:1,subvol=/@home
    32 31 0:30 /@home /home rw,noatime shared:3 - btrfs /dev/mapper/data ro,compress=zstd:1,subvol=/@home
    33 24 0:30 /@home/a/reports /srv/reports ro,noatime shared:4 - btrfs /dev/mapper/data ro,compress=zstd:1,subvol=/@home
    34 24 0:31 /@home/b /srv/share ro,noatime shared:5 - btrfs /dev/sdb1 rw,compress=zstd:1,subvol=/@home
    35 24 0:32 / /mnt/archive ro,relatime - ext4 /dev/sdc1 ro
    36 24 0:33 / /mnt/My\040"Disk" rw,relatime - ext4 /dev/sdd1 rw,errors=remount-ro,emergency_ro
    37 24 0:34 / /run/credentials/foo.service rw,nosuid,nodev,noexec,relatime,nosymfollow shared:6 - tmpfs none ro,size=1024k,mode=700,noswap
    38 24 0:35 / /run/nixos-etc-metadata rw,relatime - erofs /dev/loop0 ro,user_xattr
    39 24 0:36 / /data rw,relatime - xfs /dev/sde1 rw
  '';

  # - /var/lib, /home: `rw` mounts over a forced-`ro` btrfs; stacked /home once.
  # - /srv/reports: intended `ro` bind, even over the faulty filesystem.
  # - /srv/share, /mnt/archive, /data: `ro` bind, `ro` disk, healthy mount.
  # - credentials: dropped at the source. erofs: emitted, the rule skips it.
  expected = builtins.toFile "expected.prom" ''
    # HELP dnf_filesystem_forced_readonly Read-write mount whose filesystem the kernel turned read-only.
    # TYPE dnf_filesystem_forced_readonly gauge
    dnf_filesystem_forced_readonly{device="/dev/mapper/data",fstype="btrfs",mountpoint="/var/lib"} 1
    dnf_filesystem_forced_readonly{device="/dev/mapper/data",fstype="btrfs",mountpoint="/home"} 1
    dnf_filesystem_forced_readonly{device="/dev/sdd1",fstype="ext4",mountpoint="/mnt/My\\040\"Disk\""} 1
    dnf_filesystem_forced_readonly{device="/dev/loop0",fstype="erofs",mountpoint="/run/nixos-etc-metadata"} 1
  '';
in
pkgs.runCommand "fs-forced-readonly-check"
  {
    nativeBuildInputs = [
      pkgs.gawk
      pkgs.diffutils
      pkgs.prometheus.cli
    ];
    parser = ../../../modules/service/monitoring/fs-forced-readonly.awk;
    inherit mountinfo expected;
  }
  ''
    set -euo pipefail
    awk -f "$parser" "$mountinfo" > got.prom

    if ! diff -u "$expected" got.prom ;then
      echo "FAIL: fs-forced-readonly.awk output changed (see diff above)." >&2
      exit 1
    fi

    # Label escaping is what node_exporter's parser will choke on first.
    promtool check metrics < got.prom

    # A healthy host still exports the header, nothing else.
    head -n 1 "$mountinfo" | awk -f "$parser" > healthy.prom
    if grep -qv '^#' healthy.prom ;then
      echo "FAIL: a healthy mount table exported a series." >&2
      exit 1
    fi
    touch $out
  ''
