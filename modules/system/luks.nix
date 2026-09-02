# LUKS passphrase policy & remote unlock: shared + per-host passphrases, initrd SSH.
#
# Completes `modules/system/yubikey.nix` (FIDO2 keyslots) with the passphrase
# side of the fleet LUKS policy. Every encrypted volume carries exactly two
# managed passphrases, plus one keyslot per enrolled YubiKey:
#
# | Keyslot | Secret | Audience |
# |---|---|---|
# | shared | sops `luks-passphrase` | the fleet admin. Also **authorizes** keyslot operations (`luksAddKey` / `luksKillSlot`) for the units below, and is the key disko formats the disk with. |
# | per-host | sops `luks/<host>/passphrase` | the user of that one machine, without handing over the fleet. |
# | FIDO2 | registry `usr/secrets/yubikeys.json` | one slot per key, on every encrypted host. |
#
# Two managed passphrases and not one, because they serve different people —
# and because a rotation of either stays authorized by the other, so the sync
# unit is never left without an authorizer (it adds the new slot before killing
# the old one).
#
# There is no separate "install passphrase": `just install` formats the volume
# through `nixos-anywhere --disk-encryption-keys` with the shared passphrase, so
# the format keyslot *is* the shared keyslot.
#
# `just luks <host>` provisions a host (idempotent, also called by
# `just configure`); its `pre` phase runs offline and is called by `just install`
# before the build. It records the host in the **public** manifest
# `usr/secrets/luks.json` (committed), stores the per-host passphrase and the
# initrd SSH host key in sops, and ensures the shared `luks-passphrase` exists.
# `just luks <host> show` prints the keyslot table and audits remote unlock.
# The module then keeps everything converged at each apply:
#
# - **keyslots**: a oneshot service syncs the shared and per-host passphrases
#   into every disko-declared LUKS2 header. A changed sops value rotates the
#   corresponding keyslot (old slot killed, new one added). Keyslot operations
#   are authorized by whichever managed passphrase still unlocks the volume, so
#   one of them must remain valid. Slots outside its ledger (FIDO2, manual
#   enrollments) are never touched.
# - **remote unlock**: initrd sshd on a dedicated port (2222), own persistent
#   host key (`/var/lib/luks-initrd/`), root login with the `nix` deploy key
#   (`usr/secrets/nix.pub`). `just unlock <host>` answers the passphrase prompt
#   without a human (through the `dnf-unlock` helper shipped in the initrd);
#   `just enter <host>` is the interactive path. Both fall back to the WAN IP
#   recorded in the manifest when the VPN route died with the host. Regular
#   hosts DHCP on wired interfaces (a laptop on Wi-Fi has no initrd network and
#   falls back to console unlock); zone gateways replicate their production
#   layout instead — static LAN IP on the lan0 bridge, DHCP on the WAN side —
#   since they are themselves the DHCP server their initrd would otherwise wait
#   on.
#
# :::note[Zero configuration]
# Enabled by default but fully inert until the host appears in
# `usr/secrets/luks.json` AND declares a LUKS volume in its disko config.
# Existing encrypted hosts are unaffected until `just luks <host>` is run.
# :::
#
# :::caution[The initrd key must predate the bootloader]
# Initrd secrets are appended when the bootloader is installed, *before*
# activation. A fresh install is covered: `just install` stages the key under
# `/mnt` (`nixos-anywhere --extra-files`) so the very first boot already listens
# on 2222. On an already-running host, `just luks <host>` puts it in place over
# SSH — never add a host to `luks.json` by hand, and never apply before the key
# exists on the target.
# :::
#
# :::danger[Keyslot budget]
# LUKS2 headers hold at most 32 keyslots. Every enrolled YubiKey consumes one
# slot on every encrypted host (fleet-wide policy), plus the shared and per-host
# passphrases: the module warns when the projected total nears the limit.
# :::

{
  lib,
  config,
  pkgs,
  host,
  network,
  workDir,
  ...
}:
let
  cfg = config.darkone.system.luks;

  # Public manifest written by `just luks` (consumer workspace, committed).
  # Missing file or absent host = module inert: safe default for fresh
  # workspaces and for hosts not yet provisioned.
  manifestFile = workDir + "/usr/secrets/luks.json";
  manifest =
    if builtins.pathExists manifestFile then
      builtins.fromJSON (builtins.readFile manifestFile)
    else
      { };
  provisioned = manifest ? ${host.hostname};

  # Deploy key of the nix user: the only identity allowed into the initrd.
  nixPubFile = workDir + "/usr/secrets/nix.pub";
  hasNixPub = builtins.pathExists nixPubFile;

  # A zone gateway serves the LAN DHCP itself and its VPN dies with it, so
  # its initrd cannot rely on either: replicate the production addressing
  # (bridge lan0, static LAN IP) and DHCP only on the WAN side.
  gateway = lib.attrByPath [
    "zones"
    (host.zone or "")
    "gateway"
  ] { } network;
  isGateway = (gateway.hostname or "") == host.hostname && gateway ? lan;
  prefixLength = lib.attrByPath [
    "zones"
    (host.zone or "")
    "prefixLength"
  ] 24 network;

  # LUKS volume names, discovered from the host disko layout. Reading
  # `config.disko` (and not `config.boot.initrd.luks.devices`) avoids the
  # infinite recursion of mapping an option over itself.
  luksNames = lib.concatLists (
    lib.mapAttrsToList (
      _: disk:
      lib.concatLists (
        lib.mapAttrsToList (_: part: lib.optional ((part.content.type or "") == "luks") part.content.name) (
          disk.content.partitions or { }
        )
      )
    ) (lib.attrByPath [ "disko" "devices" "disk" ] { } config)
  );

  luksActive = cfg.enable && luksNames != [ ] && provisioned;
  luksDevices = map (n: config.boot.initrd.luks.devices.${n}.device) luksNames;

  hostSecret = "luks/${host.hostname}/passphrase";

  # Projected keyslot usage: every registry credential lands on every
  # encrypted host, plus the shared and per-host passphrase slots.
  registryFile = workDir + "/usr/secrets/yubikeys.json";
  registry =
    if builtins.pathExists registryFile then
      builtins.fromJSON (builtins.readFile registryFile)
    else
      { };
  credCount = lib.foldlAttrs (
    n: _: keys:
    n + lib.count (k: (k.credId or "") != "") (lib.attrValues keys)
  ) 0 registry;
  projectedSlots = credCount + 2;

  # Non-interactive counterpart of `systemd-tty-ask-password-agent`, which only
  # talks to a terminal and cannot be driven by a script. `just unlock <host>`
  # pipes the passphrase into this over the initrd sshd.
  #
  # It answers the prompt; it cannot say whether the passphrase was accepted —
  # systemd simply asks again on a refusal, and nothing reports that back here.
  # `just unlock` therefore confirms the unlock from the admin host, by watching
  # the machine leave its initrd.
  #
  # `#!/bin/sh` on purpose: the initrd has its own /bin (built from
  # `boot.initrd.systemd.initrdBin`) and make-initrd-ng resolves ELF
  # dependencies only — a store-path shebang would point at a bash that was
  # never copied in. Everything below is POSIX shell, no sed or grep exists
  # there either.
  initrdUnlock = pkgs.writeTextFile {
    name = "dnf-unlock";
    executable = true;
    text = ''
      #!/bin/sh
      set -u
      IFS= read -r passphrase || true
      if [ -z "$passphrase" ]; then
        echo "dnf-unlock: no passphrase on stdin" >&2
        exit 1
      fi

      # `sleep` comes from the initrd's own /bin, like `sh` above.
      # The initrd sshd answers several seconds before systemd-cryptsetup asks
      # for anything (measured: four consecutive empty polls on a plain VM).
      # Failing on an empty queue made `just unlock` spend both its passphrases
      # on a window where there was nothing to answer, then report a wrong
      # passphrase — so wait for the request instead of racing it.
      waited=0
      while :; do
        pending=0
        for ask in /run/systemd/ask-password/ask.*; do
          [ -e "$ask" ] && pending=1
        done
        [ "$pending" -eq 1 ] && break
        if [ "$waited" -ge 120 ]; then
          echo "dnf-unlock: no password request after ''${waited}s" >&2
          exit 1
        fi
        sleep 1
        waited=$((waited + 1))
      done

      answered=0
      for ask in /run/systemd/ask-password/ask.*; do
        [ -e "$ask" ] || continue
        socket=
        while IFS= read -r line; do
          case $line in
            Socket=*) socket=''${line#Socket=} ;;
          esac
        done < "$ask"
        [ -n "$socket" ] || continue
        printf %s "$passphrase" \
          | ${config.boot.initrd.systemd.package}/lib/systemd/systemd-reply-password 1 "$socket" \
          || continue
        answered=$((answered + 1))
      done
      if [ "$answered" -eq 0 ]; then
        echo "dnf-unlock: request vanished before it could be answered" >&2
        exit 1
      fi
      echo "dnf-unlock: answered $answered request(s)"
    '';
  };
in
{
  options = {
    darkone.system.luks.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Fleet LUKS passphrase policy (inert until `just luks <host>` provisions the host)";
    };

    darkone.system.luks.sshPort = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = "Initrd sshd port; distinct from 22 so the initrd host key never clashes with the system one";
    };

    # Detection only, deliberately ungated by `enable`/`provisioned`: other
    # modules need to know whether the host boots on an encrypted volume
    # (a passphrase is typed at boot) without re-deriving it from disko.
    darkone.system.luks.volumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      internal = true;
      readOnly = true;
      default = luksNames;
      description = "LUKS volumes declared by the host disko layout.";
    };
  };

  config = lib.mkIf luksActive (
    lib.mkMerge [

      #========================================================================
      # Remote unlock: sshd in the initrd, root login with the nix deploy key
      #========================================================================

      (lib.mkIf hasNixPub {

        # systemd stage 1 (already forced by the yubikey module on encrypted
        # hosts, restated here so the ssh unlock works without it) + networkd
        # in the initrd.
        boot.initrd.systemd.enable = true;
        boot.initrd.systemd.network.enable = true;

        # Regular hosts DHCP on wired interfaces; gateways replicate their
        # production layout (they ARE the DHCP server): WAN side DHCP, LAN
        # ports bridged into lan0 carrying the static zone IP.
        boot.initrd.systemd.network.netdevs = lib.mkIf isGateway {
          lan0.netdevConfig = {
            Kind = "bridge";
            Name = "lan0";
          };
        };
        boot.initrd.systemd.network.networks = lib.mkMerge [
          (lib.mkIf isGateway {
            "20-dnf-wan" = {
              matchConfig.Name = gateway.wan.interface;
              networkConfig.DHCP = "yes";
            };
            "30-dnf-lan-ports" = {
              matchConfig.Name = gateway.lan.interfaces;
              networkConfig.Bridge = "lan0";
            };
            "40-dnf-lan0" = {
              matchConfig.Name = "lan0";
              networkConfig.Address = "${gateway.lan.ip}/${toString prefixLength}";
            };
          })
          (lib.mkIf (!isGateway) {
            "99-dnf-initrd" = {
              matchConfig.Name = [
                "en*"
                "eth*"
              ];
              networkConfig.DHCP = "yes";
            };
          })
        ];

        # Hardware configs reliably carry storage modules but rarely NICs:
        # ship the common wired drivers so DHCP works out of the box, plus
        # the bridge module for the gateway lan0.
        boot.initrd.availableKernelModules = [
          "bridge"
          "virtio_net"

          # `e1000` is the 82540EM emulated by VirtualBox and QEMU, a different
          # driver from the `e1000e` of physical Intel NICs: without it a test
          # VM boots into an initrd with no network at all, and remote unlock
          # silently does not exist.
          "e1000"
          "e1000e"
          "igb"
          "igc"
          "r8169"
        ];

        # The host key lives outside the store (appended to the initrd as a
        # secret at bootloader install). It is generated once by
        # `just luks <host> pre`, kept in sops, and staged into `/mnt` by
        # `just install`; the oneshot below only covers a wiped /var/lib
        # (takes effect at the next rebuild).
        boot.initrd.network.ssh = {
          enable = true;
          port = cfg.sshPort;
          hostKeys = [ "/var/lib/luks-initrd/ssh_host_ed25519_key" ];
          authorizedKeys = [ (lib.fileContents nixPubFile) ];
        };

        # make-initrd-ng copies the binaries it is handed, not whole packages,
        # and systemd-reply-password lives under lib/systemd: without this it is
        # simply absent and only the interactive agent can be reached.
        boot.initrd.systemd.storePaths = [
          "${config.boot.initrd.systemd.package}/lib/systemd/systemd-reply-password"
        ];
        boot.initrd.systemd.extraBin.dnf-unlock = initrdUnlock;

        # The bootloader appends this key to the initrd verbatim. `--extra-files`
        # drops it in as root, but a key restored by hand — or inherited from an
        # older provisioning — can be looser.
        system.activationScripts.luksInitrdKeyPerms = ''
          if [ -d /var/lib/luks-initrd ]; then
            ${pkgs.coreutils}/bin/chown -R root:root /var/lib/luks-initrd
            ${pkgs.coreutils}/bin/chmod 700 /var/lib/luks-initrd
            [ ! -e /var/lib/luks-initrd/ssh_host_ed25519_key ] \
              || ${pkgs.coreutils}/bin/chmod 600 /var/lib/luks-initrd/ssh_host_ed25519_key
            [ ! -e /var/lib/luks-initrd/ssh_host_ed25519_key.pub ] \
              || ${pkgs.coreutils}/bin/chmod 644 /var/lib/luks-initrd/ssh_host_ed25519_key.pub
          fi
        '';

        systemd.services.luks-initrd-keygen = {
          description = "Generate the initrd SSH host key when missing";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            key=/var/lib/luks-initrd/ssh_host_ed25519_key
            if [ ! -s "$key" ]; then
              ${pkgs.coreutils}/bin/mkdir -p /var/lib/luks-initrd
              ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f "$key"
              echo "initrd SSH host key generated (embedded at next rebuild)"
            fi
          '';
        };
      })

      #========================================================================
      # Keyslots: converge shared + per-host passphrases into every header
      #========================================================================

      {

        # Both provisioned by `just luks`; sops-nix fails the activation if a
        # key is missing from secrets.yaml, hence the manifest gating above.
        # restartUnits: a rotated sops value converges at the same apply
        # instead of waiting for the next boot.
        sops.secrets = {
          luks-passphrase.restartUnits = [ "luks-passphrase-sync.service" ];
          ${hostSecret}.restartUnits = [ "luks-passphrase-sync.service" ];
        };

        warnings = lib.optional (projectedSlots >= 25) ''
          darkone.system.luks: ${toString credCount} YubiKey credentials are enrolled
          fleet-wide; with the shared and per-host passphrases this projects
          ${toString projectedSlots} keyslots per volume (LUKS2 caps at 32). Consider
          revoking unused keys.
        '';

        # Idempotent sync of the managed passphrase keyslots. A ledger records
        # (label, device, secret hash, slot) so a changed sops value rotates
        # its keyslot; slots outside the ledger (FIDO2, manual enrollments) are
        # never touched. Any failure is logged and skipped: this unit must never
        # block a deployment or a boot.
        systemd.services.luks-passphrase-sync = {
          description = "Sync managed passphrases into LUKS headers";
          wantedBy = [ "multi-user.target" ];

          # Runs before the FIDO2 enrollment: a freshly rotated shared
          # passphrase must land before that unit tries to authorize with it.
          before = [ "yubikey-luks-enroll.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -euo pipefail

            # slot_of parses cryptsetup's "Key slot N unlocked" message: force
            # the C locale so a localized system (fr_FR, …) does not turn every
            # successful unlock test into a silent mismatch.
            export LC_ALL=C
            cs=${pkgs.cryptsetup}/bin/cryptsetup
            awk=${pkgs.gawk}/bin/awk
            grep=${pkgs.gnugrep}/bin/grep
            sed=${pkgs.gnused}/bin/sed

            ledger=/var/lib/luks-passphrase/ledger
            ${pkgs.coreutils}/bin/mkdir -p /var/lib/luks-passphrase
            ${pkgs.coreutils}/bin/touch "$ledger"

            # Prints the keyslot a passphrase unlocks, empty when invalid.
            # Always returns 0: an invalid passphrase is an expected outcome,
            # not an error (`set -e` would abort on the failed pipeline).
            slot_of() {
              $cs --verbose open --test-passphrase --key-file="$2" "$1" 2>&1 \
                | $sed -n 's/^Key slot \([0-9]\+\) unlocked.*/\1/p' | ${pkgs.coreutils}/bin/head -n1 || true
            }

            for dev in ${lib.escapeShellArgs luksDevices}; do
              if [ ! -e "$dev" ]; then
                echo "device $dev not found, skipped"
                continue
              fi
              if ! $cs isLuks --type luks2 "$dev" 2>/dev/null; then
                echo "$dev is not a LUKS2 device, skipped"
                continue
              fi

              # Authorizer: any managed passphrase that still unlocks $dev.
              auth=""
              for f in "$SHARED" "$PERHOST"; do
                if [ -s "$f" ] && [ -n "$(slot_of "$dev" "$f")" ]; then
                  auth=$f
                  break
                fi
              done

              for entry in "shared:$SHARED" "host:$PERHOST"; do
                label=''${entry%%:*}
                f=''${entry#*:}
                if [ ! -s "$f" ]; then
                  echo "$label passphrase secret is empty, skipped"
                  continue
                fi
                hash=$(${pkgs.coreutils}/bin/sha256sum "$f" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
                old=$($grep "^$label $dev " "$ledger" | ${pkgs.coreutils}/bin/tail -n1 || true)
                oldhash=$(printf '%s' "$old" | $awk '{print $3}')
                oldslot=$(printf '%s' "$old" | $awk '{print $4}')

                # Already valid: just refresh the ledger (hash or slot may
                # have changed out-of-band).
                slot=$(slot_of "$dev" "$f")
                if [ -z "$slot" ]; then
                  if [ -z "$auth" ]; then
                    echo "no managed passphrase unlocks $dev, cannot enroll $label (fix one slot manually)"
                    continue
                  fi
                  if ! $cs luksAddKey --key-file="$auth" "$dev" "$f"; then
                    echo "luksAddKey failed on $dev for $label, skipped"
                    continue
                  fi
                  slot=$(slot_of "$dev" "$f")
                  echo "enrolled $label passphrase on $dev (slot $slot)"

                  # Rotation: the sops value changed, retire the old keyslot.
                  if [ -n "$oldslot" ] && [ "$oldhash" != "$hash" ] && [ "$oldslot" != "$slot" ]; then
                    if $cs luksKillSlot -q --key-file="$f" "$dev" "$oldslot"; then
                      echo "rotated $label passphrase on $dev (killed slot $oldslot)"
                    else
                      echo "could not kill old slot $oldslot on $dev, left in place"
                    fi
                  fi
                fi
                $sed -i "\#^$label $dev #d" "$ledger"
                echo "$label $dev $hash $slot" >> "$ledger"
              done
            done
          '';
          environment = {
            SHARED = config.sops.secrets.luks-passphrase.path;
            PERHOST = config.sops.secrets.${hostSecret}.path;
          };
        };
      }
    ]
  );
}
