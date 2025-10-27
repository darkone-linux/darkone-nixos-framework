#!/usr/bin/env bash
set -euo pipefail

# TODO: auto find this:
ISO_PATH="/nix/store/pa0sfka23gn1inlhbm26nyv7f0507p0g-nixos-minimal-25.11.20251015.544961d-x86_64-linux.iso/iso/nixos-minimal-25.11.20251015.544961d-x86_64-linux.iso"
BRIDGE_IF="enp2s0"

GW_NAME="dnf-test-gateway"
HS_NAME="dnf-test-headscale"
ND_NAME="dnf-test-node"

DISK_SIZE=102400

exists_natnetwork() {
    VBoxManage list natnetworks | grep -e "Name: *$1"
}

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

    if [ "${VM_NAME}" == "${GW_NAME}" ] ;then
        VBoxManage modifyvm "${VM_NAME}" \
        --memory 4096 \
        --cpus 2 \
        --firmware efi \
        --usb on --usbehci on \
        --graphicscontroller VBoxSVGA --vram 16 \
        --nic1 bridged --bridgeadapter1 "${BRIDGE_IF}" \
        --nic2 natnetwork --nat-network2 "LanNet" #\
        #  --nic3 natnetwork --nat-network3 "WanNet"
    fi

    if [ "${VM_NAME}" == "${HS_NAME}" ] ;then
        VBoxManage modifyvm "${VM_NAME}" \
        --memory 4096 \
        --cpus 2 \
        --firmware efi \
        --usb on --usbehci on \
        --graphicscontroller VBoxSVGA --vram 16 \
        --nic1 bridged --bridgeadapter1 "${BRIDGE_IF}" #\
        #  --nic2 natnetwork --nat-network2 "WanNet"
    fi

    if [ "${VM_NAME}" == "${ND_NAME}" ] ;then
        VBoxManage modifyvm "${VM_NAME}" \
        --memory 4096 \
        --cpus 2 \
        --firmware efi \
        --usb on --usbehci on \
        --graphicscontroller VBoxSVGA --vram 16 \
        --nic1 natnetwork --nat-network1 "LanNet"
    fi

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

    if ! VBoxManage showvminfo "${VM_NAME}" | grep -q "${ISO_PATH}"; then
        VBoxManage storageattach "${VM_NAME}" \
        --storagectl "IDE Controller" --port 0 --device 0 \
        --type dvddrive --medium "${ISO_PATH}"
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

    # VBoxManage showvminfo "${VM_NAME}" | grep -E "Name:|Memory size:|Number of CPUs:|NIC"

    echo "→ To start the VM:"
    echo "  VBoxManage startvm \"${VM_NAME}\" --type gui"
}

#------------------------------------------------------------------------------
# NETWORKS
#------------------------------------------------------------------------------

# if exists_natnetwork "WanNet"; then
#     echo "→ NAT network 'WanNet' already exists."
# else
#     echo "→ Creating NAT network 'WanNet'..."
#     VBoxManage natnetwork add \
#         --netname "WanNet" \
#         --network "10.0.2.0/24" \
#         --dhcp on \
#         --ipv6 off \
#         --enable
# fi

if exists_natnetwork "LanNet"; then
    echo "→ NAT network 'LanNet' already exists."
else
    echo "→ Creating NAT network 'LanNet'..."
    VBoxManage natnetwork add \
        --netname "LanNet" \
        --network "10.42.2.0/24" \
        --dhcp off \
        --ipv6 off \
        --enable
fi

#------------------------------------------------------------------------------
# VMS
#------------------------------------------------------------------------------

create_vm $GW_NAME
create_vm $HS_NAME
create_vm $ND_NAME
