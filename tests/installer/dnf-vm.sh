# DNF — a QEMU machine for the installer: UEFI, one disk, user networking.
#
#   dnf-vm --state DIR [--iso ISO] [--gui] [--memory MiB] [--disk-size SIZE]
#          [--serial SOCK] [--qmp SOCK] [--usb IMG] [--ssh-port N]
#          [--unlock-port N]
#
# Shared by `nix run .#try` (a window, a persistent DIR) and the installer test
# (`run.py`: serial console and QMP sockets, a USB stick). DIR holds the disk
# and the UEFI variables, created when missing. The disk boots first: a blank
# one falls through to the ISO.
#
# - `--usb`: raw image on an xHCI port, device id `stick`, block node
#   `stick-raw`: QMP `device_del` unplugs it, `device_add` plugs it back;
# - `--ssh-port`, `--unlock-port`: 127.0.0.1 forwards to 22 and to 2222, the
#   initrd sshd of an encrypted host (dnf/modules/system/luks.nix).
#
# OVMF_FV, the OVMF firmware directory, is set by the Nix wrapper.

set -euo pipefail

state=""
iso=""
gui=false
memory=8192
diskSize=64G
serial=""
qmp=""
usb=""
sshPort=""
unlockPort=""
while [ $# -gt 0 ]; do
  case "$1" in
  --state) state="$2" && shift 2 ;;
  --iso) iso="$2" && shift 2 ;;
  --gui) gui=true && shift ;;
  --memory) memory="$2" && shift 2 ;;
  --disk-size) diskSize="$2" && shift 2 ;;
  --serial) serial="$2" && shift 2 ;;
  --qmp) qmp="$2" && shift 2 ;;
  --usb) usb="$2" && shift 2 ;;
  --ssh-port) sshPort="$2" && shift 2 ;;
  --unlock-port) unlockPort="$2" && shift 2 ;;
  *)
    echo "dnf-vm: unknown argument '$1'" >&2
    exit 2
    ;;
  esac
done
[ -n "$state" ] || {
  echo "dnf-vm: --state DIR is required" >&2
  exit 2
}

mkdir -p "$state"
[ -f "$state/disk.qcow2" ] || qemu-img create -q -f qcow2 "$state/disk.qcow2" "$diskSize"
if [ ! -f "$state/vars.fd" ]; then
  install -m 644 "$OVMF_FV/OVMF_VARS.fd" "$state/vars.fd"
fi

# KVM when the host has it, else (much slower) emulation.
args=(
  -machine q35 -accel kvm -accel tcg -cpu max -smp 4 -m "$memory"
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_FV/OVMF_CODE.fd"
  -drive "if=pflash,format=raw,file=$state/vars.fd"
  -drive "file=$state/disk.qcow2,if=none,id=disk,format=qcow2"
  -device "virtio-blk-pci,drive=disk,serial=DNFVM0001,bootindex=1"
  -device "qemu-xhci,id=xhci"
)
if [ -n "$iso" ]; then
  args+=(
    -drive "file=$iso,media=cdrom,if=none,id=cd,readonly=on"
    -device "ide-cd,drive=cd,bootindex=2"
  )
fi

fwd=""
[ -z "$sshPort" ] || fwd+=",hostfwd=tcp:127.0.0.1:$sshPort-:22"
[ -z "$unlockPort" ] || fwd+=",hostfwd=tcp:127.0.0.1:$unlockPort-:2222"
args+=(-nic "user,model=virtio-net-pci$fwd")

if [ -n "$usb" ]; then
  args+=(
    -blockdev "driver=file,filename=$usb,node-name=stick-file"
    -blockdev "driver=raw,file=stick-file,node-name=stick-raw"
    -device "usb-storage,bus=xhci.0,drive=stick-raw,id=stick,removable=on"
  )
fi
if $gui; then
  args+=(-vga virtio -display gtk -device "usb-tablet,bus=xhci.0")
else
  args+=(-vga std -display none)
fi
[ -z "$serial" ] || args+=(-chardev "socket,id=ser0,path=$serial,server=on,wait=off" -serial chardev:ser0)
[ -z "$qmp" ] || args+=(-qmp "unix:$qmp,server=on,wait=off")

exec qemu-system-x86_64 "${args[@]}"
