# DNF — the box of the installer test: QEMU's user network, shared.
#
#   dnf-box [--forward PORT] --link LOCAL,PEER [--link LOCAL,PEER]...
#
# A QEMU without machine: its user network (10.0.2.0/24: NAT, DHCP, DNS, as an
# ISP box) on a hub, one hub port per `--link`. No bridge, no tap, no root.
#
# - `--link`: UDP point-to-point on 127.0.0.1, ports LOCAL and PEER;
# - a hub floods: slirp takes every IP frame it sees for its NAT, a TCP flow
#   between two machines included, and resets it. Several machines: one link
#   to a learning switch (`Switch` of run.py), the machines on it;
# - leases: 10.0.2.15 onwards, in the order of the first requests, kept by MAC
#   as long as the box runs;
# - `--forward`: 127.0.0.1:PORT to port 22 of the first lease (10.0.2.15);
# - IPv4 only. Runs until killed.
#
# shellcheck shell=bash # body of a `writeShellApplication`: no shebang

set -euo pipefail

forward=""
links=()
while [ $# -gt 0 ]; do
  case "$1" in
  --forward) forward="$2" && shift 2 ;;
  --link) links+=("$2") && shift 2 ;;
  *)
    echo "dnf-box: unknown argument '$1'" >&2
    exit 2
    ;;
  esac
done
[ ${#links[@]} -gt 0 ] || {
  echo "dnf-box: at least one --link LOCAL,PEER is required" >&2
  exit 2
}

fwd=""
[ -z "$forward" ] || fwd=",hostfwd=tcp:127.0.0.1:$forward-10.0.2.15:22"
args=(
  -machine none -nodefaults -display none
  -netdev "user,id=box,ipv6=off$fwd"
  -netdev "hubport,id=hub-box,hubid=0,netdev=box"
)
for i in "${!links[@]}"; do
  IFS=, read -r localPort peerPort <<<"${links[i]}"
  args+=(
    -netdev "socket,id=port$i,udp=127.0.0.1:$peerPort,localaddr=127.0.0.1:$localPort"
    -netdev "hubport,id=hub-port$i,hubid=0,netdev=port$i"
  )
done

exec qemu-system-x86_64 "${args[@]}"
