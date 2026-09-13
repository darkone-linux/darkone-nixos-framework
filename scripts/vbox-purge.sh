#!/usr/bin/env bash
set -euo pipefail

VM_PREFIX="vbox-"
VM_COUNT=10
VM_PATH="$HOME/VirtualBox VMs"

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

for i in $(seq 1 "$VM_COUNT"); do
    delete_vm $(printf "$VM_PREFIX%'02d" "$i")
done
