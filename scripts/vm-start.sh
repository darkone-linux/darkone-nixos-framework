#!/usr/bin/env bash
# Start a QEMU/KVM test VM on the local DNF ISO, bridged on the LAN.
#
# Usage, from the project root: dnf/scripts/vm-start.sh <hostname> [qemu args]
#
# - Disk var/vm/<hostname>.qcow2 (40G, created once) + UEFI vars alongside.
# - Boots the disk first, the ISO as fallback: an empty disk boots the installer.
# - Host prerequisite: `darkone.graphic.qemu` (bridge + qemu-bridge-helper).
set -euo pipefail

WORK_DIR="${WORKDIR:-$PWD}"
BRIDGE="${BRIDGE:-br0}"
HELPER="/run/wrappers/bin/qemu-bridge-helper"
DISK_SIZE="${DISK_SIZE:-40G}"
DISK_BUS="${DISK_BUS:-sata}"
MEMORY="${MEMORY:-4096}"
CPUS="${CPUS:-2}"

fail() {
    echo "✗ $*" >&2
    exit 1
}

if [ $# -lt 1 ] || [[ ! "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    fail "Usage: $0 <hostname> [qemu args...]"
fi
NAME="$1"
shift

ISO_FILE=""
for f in "${WORK_DIR}"/result/iso/*.iso; do
    [ -f "$f" ] && ISO_FILE="$(readlink -f "$f")"
done
[ -n "${ISO_FILE}" ] || fail "No ISO in ${WORK_DIR}/result/iso: run 'just build-iso' first."

command -v qemu-system-x86_64 >/dev/null || fail "qemu not found: enable darkone.graphic.qemu on this host."
[ -w /dev/kvm ] || fail "/dev/kvm is not writable: KVM unavailable."
[ -d "/sys/class/net/${BRIDGE}/bridge" ] || fail "Bridge '${BRIDGE}' not found (override with BRIDGE=<if>)."
[ -x "${HELPER}" ] || fail "${HELPER} missing: enable darkone.graphic.qemu on this host."
grep -qx "allow ${BRIDGE}" /etc/qemu/bridge.conf 2>/dev/null \
    || fail "'${BRIDGE}' is not allowed in /etc/qemu/bridge.conf."

# SATA shows up as /dev/sda, NVMe as /dev/nvme0n1: match the host disko layout.
case "${DISK_BUS}" in
    sata) DISK_DEVICE="ide-hd,bus=ide.0" ;;
    nvme) DISK_DEVICE="nvme,serial=${NAME:0:20}" ;;
    *) fail "DISK_BUS must be 'sata' or 'nvme'." ;;
esac

VM_DIR="${WORK_DIR}/var/vm"
DISK="${VM_DIR}/${NAME}.qcow2"
VARS="${VM_DIR}/${NAME}.vars.fd"
FIRMWARE="$(dirname "$(readlink -f "$(command -v qemu-system-x86_64)")")/../share/qemu"
mkdir -p "${VM_DIR}"

if [ ! -f "${DISK}" ]; then
    echo "→ Creating ${DISK_SIZE} disk: ${DISK}"
    qemu-img create -q -f qcow2 "${DISK}" "${DISK_SIZE}"
fi

# Writable per-VM copy: boot entries written by the installed system persist.
[ -f "${VARS}" ] || install -m 644 "${FIRMWARE}/edk2-i386-vars.fd" "${VARS}"

# QEMU OUI, stable per hostname: declare it as `mac` in etc/config.yaml to pin
# the VM address. The QEMU default MAC would collide between VMs on the LAN.
HASH="$(printf '%s' "${NAME}" | sha256sum)"
MAC="52:54:00:${HASH:0:2}:${HASH:2:2}:${HASH:4:2}"

echo "→ VM ${NAME}: MAC ${MAC}, bridge ${BRIDGE}, ${DISK_BUS} disk"
echo "→ Using ISO: ${ISO_FILE}"
exec qemu-system-x86_64 \
    -name "${NAME}" \
    -machine q35,accel=kvm -cpu host -smp "${CPUS}" -m "${MEMORY}" \
    -drive "if=pflash,format=raw,readonly=on,file=${FIRMWARE}/edk2-x86_64-code.fd" \
    -drive "if=pflash,format=raw,file=${VARS}" \
    -drive "if=none,id=disk0,format=qcow2,file=${DISK}" \
    -device "${DISK_DEVICE},drive=disk0,bootindex=1" \
    -drive "if=none,id=cd0,media=cdrom,readonly=on,file=${ISO_FILE}" \
    -device "ide-cd,bus=ide.1,drive=cd0,bootindex=2" \
    -netdev "bridge,id=net0,br=${BRIDGE},helper=${HELPER}" \
    -device "virtio-net-pci,netdev=net0,mac=${MAC}" \
    "$@"
