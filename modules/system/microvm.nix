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
# - Hypervisor side (`microvm/host.nix`): one routed tap per guest (no bridge),
#   whole host on networkd with the zone gateway as static resolver, proxy ARP
#   on the LAN, nftables isolation (`dnf-microvm` table), `<stateDir>` closed
#   to the hypervisor's users (0770) and bound `nosuid,nodev` (setuid files,
#   device nodes of a guest inert).
# - Speech to text (`microvm/whisper.nix`): one whisper.cpp server on the
#   hypervisor for the guests with `darkone.system.microvm.guest.whisper`
#   (OpenClaw voice notes), started and opened for them only; `whisper.model`,
#   `whisper.threads` tune it.
#
# :::note[Deployment]
# Guests are no colmena nodes: deploying the hypervisor builds and restarts
# the guests whose system changed.
# :::
#
# :::caution[Store optimisation]
# Off on a hypervisor: its store is the lower layer of the guests' store
# overlay, which answers ESTALE once `nix-store --optimise` relinks a file a
# running guest has read. Never run it by hand there either.
# :::
#
# :::caution[Isolation]
# A guest reaches the Internet and the zone gateway DNS, nothing else on the
# LAN; of the hypervisor, only the services it asks for (whisper). Only the
# zone gateway (reverse proxy, monitoring) reaches a guest.
# :::

{
  lib,
  pkgs,
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
    darkone.system.microvm.guest.whisper = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use the hypervisor's whisper.cpp server (speech to text): started and opened to this guest.";
    };
    darkone.system.microvm.guestInputRules = lib.mkOption {
      type = lib.types.lines;
      default = "";
      internal = true;
      description = "nftables rules of the hypervisor's `dnf-microvm` input chain, before the drop of guest traffic.";
    };
    darkone.system.microvm.whisper.model = lib.mkOption {
      type = lib.types.path;
      default = pkgs.fetchurl {
        url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin";
        sha256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69";
      };
      defaultText = lib.literalMD "whisper.cpp ggml `large-v3-turbo` model (1.6 GB)";
      description = "whisper.cpp ggml model of the hypervisor's server, loaded once for all guests.";
    };
    darkone.system.microvm.whisper.threads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Threads of the hypervisor's whisper.cpp server, one transcription at a time.";
    };
  };
}
