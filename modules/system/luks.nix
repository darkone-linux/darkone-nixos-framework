# LUKS passphrase policy & remote unlock: shared + per-host passphrases, initrd SSH.
#
# Completes `modules/system/yubikey.nix` (FIDO2 keyslots) with the passphrase
# side of the fleet LUKS policy. `just luks <host>` provisions a host: it
# records it in the **public** manifest `usr/secrets/luks.json` (committed),
# stores the per-host passphrase in sops (`luks/<host>/passphrase`), ensures
# the shared `luks-passphrase` exists, and pre-generates the initrd SSH host
# key on the target. The module then keeps everything converged at each apply:
#
# - **keyslots**: a oneshot service syncs the shared and per-host passphrases
#   into every disko-declared LUKS2 header. A changed sops value rotates the
#   corresponding keyslot (old slot killed, new one added). Keyslot operations
#   are authorized by whichever managed passphrase still unlocks the volume,
#   so one of them must remain valid — the disko install keyslot is never
#   touched and remains the last-resort fallback.
# - **remote unlock**: initrd sshd on a dedicated port (2222), own persistent
#   host key (`/var/lib/luks-initrd/`), root login with the `nix` deploy key
#   (`usr/secrets/nix.pub`). `just enter <host>` detects a host waiting in
#   initrd and answers the passphrase prompt via
#   `systemd-tty-ask-password-agent`. DHCP on wired interfaces only: a laptop
#   on Wi-Fi has no initrd network and falls back to console unlock.
#
# :::note[Zero configuration]
# Enabled by default but fully inert until the host appears in
# `usr/secrets/luks.json` AND declares a LUKS volume in its disko config.
# Existing encrypted hosts are unaffected until `just luks <host>` is run.
# :::
#
# :::caution[Provision before you apply]
# The initrd host key must exist on the target when the bootloader is
# installed (initrd secrets are appended at that point, *before* activation).
# `just luks <host>` creates it over SSH; never add a host to `luks.json` by
# hand. Reinstalling a provisioned host with nixos-anywhere needs the key
# staged under `/mnt` (`--extra-files`) or the host dropped from the manifest
# first.
# :::
#
# :::danger[Keyslot budget]
# LUKS2 headers hold at most 32 keyslots. Every enrolled YubiKey consumes one
# slot on every encrypted host (fleet-wide policy), plus install + shared +
# per-host passphrases: the module warns when the projected total nears the
# limit.
# :::

{
  lib,
  config,
  pkgs,
  host,
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
  # encrypted host, plus install + shared + per-host passphrase slots.
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
  projectedSlots = credCount + 3;
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
  };

  config = lib.mkIf luksActive (
    lib.mkMerge [

      #========================================================================
      # Remote unlock: sshd in the initrd, root login with the nix deploy key
      #========================================================================

      (lib.mkIf hasNixPub {

        # systemd stage 1 (already forced by the yubikey module on encrypted
        # hosts, restated here so the ssh unlock works without it) + networkd
        # in the initrd, DHCP on wired interfaces.
        boot.initrd.systemd.enable = true;
        boot.initrd.systemd.network.enable = true;
        boot.initrd.systemd.network.networks."99-dnf-initrd" = {
          matchConfig.Name = [
            "en*"
            "eth*"
          ];
          networkConfig.DHCP = "yes";
        };

        # Hardware configs reliably carry storage modules but rarely NICs:
        # ship the common wired drivers so DHCP works out of the box.
        boot.initrd.availableKernelModules = [
          "virtio_net"
          "e1000e"
          "igb"
          "igc"
          "r8169"
        ];

        # The host key lives outside the store (appended to the initrd as a
        # secret at bootloader install); `just luks <host>` pre-generates it,
        # the oneshot below regenerates it if /var/lib is ever wiped (takes
        # effect at the next rebuild).
        boot.initrd.network.ssh = {
          enable = true;
          port = cfg.sshPort;
          hostKeys = [ "/var/lib/luks-initrd/ssh_host_ed25519_key" ];
          authorizedKeys = [ (lib.fileContents nixPubFile) ];
        };

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
        sops.secrets = {
          luks-passphrase = { };
          ${hostSecret} = { };
        };

        warnings = lib.optional (projectedSlots >= 25) ''
          darkone.system.luks: ${toString credCount} YubiKey credentials are enrolled
          fleet-wide; with the install, shared and per-host passphrases this projects
          ${toString projectedSlots} keyslots per volume (LUKS2 caps at 32). Consider
          revoking unused keys.
        '';

        # Idempotent sync of the managed passphrase keyslots. A ledger records
        # (label, device, secret hash, slot) so a changed sops value rotates
        # its keyslot; slots outside the ledger (install passphrase, FIDO2,
        # manual enrollments) are never touched. Any failure is logged and
        # skipped: this unit must never block a deployment or a boot.
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
