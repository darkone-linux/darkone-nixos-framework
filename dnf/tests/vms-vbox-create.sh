#!/usr/bin/env bash
set -euo pipefail

# TODO: auto find this:
ISO_FILE="latest-nixos-minimal-x86_64-linux.iso"
ISO_HTTP="https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso"
BRIDGE_IF="enp2s0"

VM_PREFIX="vbox-"
VM_COUNT=10

DISK_SIZE=102400

if [ ! -f $ISO_FILE ] ;then
  wget $ISO_HTTP
fi

exists_vm() {
    VBoxManage list vms | grep -q "\"$1\""
}

create_vm() {

    local VM_NAME="$1"
    local DISK_PATH="$HOME/VirtualBox VMs/${VM_NAME}/${VM_NAME}.vdi"

    if exists_vm "${VM_NAME}"; then
        echo "→ VM '${VM_NAME}' already exists."
    else
        echo "→ Creating VM '${VM_NAME}'..."
        VBoxManage createvm --name "${VM_NAME}" --ostype "Linux_64" --register
    fi

    VBoxManage modifyvm "${VM_NAME}" \
        --memory 4096 \
        --cpus 2 \
        --firmware efi \
        --usb on --usbehci on \
        --graphicscontroller VBoxSVGA --vram 16 \
        --nic1 bridged

    if [ ! -f "${DISK_PATH}" ]; then
        echo "→ Creating VDI disk (${DISK_SIZE} MiB)..."
        mkdir -p "$(dirname "${DISK_PATH}")"
        VBoxManage createmedium disk --filename "${DISK_PATH}" --size "${DISK_SIZE}" --format VDI
    else
        echo "→ Disk already exists: ${DISK_PATH}"
    fi

    if ! VBoxManage showvminfo "${VM_NAME}" --machinereadable | grep -q 'storagecontrollername1="IDE Controller"'; then
        VBoxManage storagectl "${VM_NAME}" --name "IDE Controller" --add ide --controller PIIX4
        echo "→ IDE controller added (PIIX4)."
    else
        echo "→ IDE controller already configured."
    fi

    if ! VBoxManage showvminfo "${VM_NAME}" | grep -q "${ISO_FILE}"; then
        VBoxManage storageattach "${VM_NAME}" \
        --storagectl "IDE Controller" --port 0 --device 0 \
        --type dvddrive --medium "${ISO_FILE}"
        echo "→ ISO attached to IDE Controller (PIIX4)."
    else
        echo "→ ISO already attached."
    fi

    if ! VBoxManage showvminfo "${VM_NAME}" --machinereadable | grep -q 'storagecontrollername0="SATA Controller"'; then
        VBoxManage storagectl "${VM_NAME}" --name "SATA Controller" --add sata --controller IntelAhci
        echo "→ SATA controller added."
    else
        echo "→ SATA controller already configured."
    fi

    if ! VBoxManage showvminfo "${VM_NAME}" | grep -q "${VM_NAME}.vdi"; then
        VBoxManage storageattach "${VM_NAME}" \
        --storagectl "SATA Controller" --port 0 --device 0 \
        --type hdd --medium "${DISK_PATH}"
        echo "→ Disk attached."
    else
        echo "→ Disk already attached."
    fi

    echo "→ To start the VM:"
    echo "  VBoxManage startvm \"${VM_NAME}\" --type gui"
}

#------------------------------------------------------------------------------
# VMS
#------------------------------------------------------------------------------

for i in $(seq 1 "$VM_COUNT"); do
    create_vm $(printf "$VM_PREFIX%'02d" "$i")
done
