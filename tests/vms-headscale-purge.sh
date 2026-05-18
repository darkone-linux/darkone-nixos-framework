#!/usr/bin/env bash
set -euo pipefail

GW_NAME="dnf-test-gateway"
HS_NAME="dnf-test-headscale"
ND_NAME="dnf-test-node"
VM_PATH="$HOME/VirtualBox VMs"

delete_natnetwork() {
    local NET="$1"
    if VBoxManage list natnetworks | grep -e "Name: *$NET"; then
        echo "→ Delete network NAT '$NET'..."
        VBoxManage natnetwork remove --netname "$NET"
    else
        echo "→ NAT '$NET' network not found."
    fi
}

delete_vm() {
    local VM="$1"
    if VBoxManage list vms | grep -q "\"$VM\""; then
        echo "→ Delete VM '$VM'..."
        VBoxManage unregistervm "$VM" --delete
    else
        echo "→ VM '$VM' not found."
    fi
    if [ -d "${VM_PATH}/$VM" ]; then
        echo "→ Delete files: ${VM_PATH}/$VM"
        rm -rf "${VM_PATH}/$VM"
    else
        echo "→ VM '$VM' directory already deleted."
    fi
}

delete_vm "${GW_NAME}"
delete_vm "${HS_NAME}"
delete_vm "${ND_NAME}"
delete_natnetwork "WanNet"
delete_natnetwork "LanNet"
