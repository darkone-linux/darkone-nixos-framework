# MicroVM guests (microvm.nix, cloud-hypervisor) on a DNF hypervisor host.
#
# A guest is an ordinary DNF host of the inventory, flagged with the
# `microvm-guest:<hypervisor>` feature in `etc/config.yaml`. It keeps its zone
# IP, services and monitoring; the hypervisor runs it and deploys it.
#
# ```yaml
# - hostname: "space1"
#   zone: "cp:1.40"              # fixed IP: tap + MAC are derived from it
#   profile: "ai-space"
#   features: ["microvm-guest:ms-a2", "monitoring-node"] # monitored like any host
# ```
#
# - Guest side (`microvm/guest.nix`): virtiofs shares under
#   `<stateDir>/<guest>/{persist,var-lib,home}`, read-only host store, host
#   key on `/persist`, static `/32` link routed by the hypervisor.
# - Hypervisor side (`microvm/host.nix`): one routed tap per guest (no bridge,
#   uplink untouched), proxy ARP on the LAN, nftables isolation (`dnf-microvm`
#   table), `<stateDir>` closed to the hypervisor's users (0770).
#
# :::note[Deployment]
# Guests are no colmena nodes: deploying the hypervisor builds and restarts
# the guests whose system changed.
# :::
#
# :::caution[Isolation]
# A guest reaches the Internet and the zone gateway DNS, nothing else on the
# LAN, not even the hypervisor. Only the zone gateway (reverse proxy,
# monitoring) reaches a guest.
# :::

{
  lib,
  dnfLib,
  host,
  hosts,
  ...
}:
{
  options = {
    darkone.system.microvm.hypervisor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = dnfLib.getMicrovmHypervisor hosts host;
      defaultText = lib.literalMD "the `microvm-guest:<host>` feature";
      readOnly = true;
      description = "Hypervisor running this host as a microVM guest, null when bare metal.";
    };
    darkone.system.microvm.stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms";
      description = "Hypervisor directory holding one sub-directory of shares per guest.";
    };
    darkone.system.microvm.guest.vcpu = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Guest virtual CPUs.";
    };
    darkone.system.microvm.guest.mem = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = "Guest RAM, in MiB.";
    };
  };
}
