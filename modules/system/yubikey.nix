# YubiKey strong authentication: fleet-wide PAM U2F + declarative FIDO2 LUKS.
#
# One physical enrollment per (user, key) on the admin host — `just yubikey
# <user> [key] [action]` — feeds:
#
# - a **public** registry `usr/secrets/yubikeys.json` in the consumer
#   workspace: pamu2fcfg credential, FIDO2 hmac-secret credential id and salt
#   (all useless without the physical key, hence committable);
# - one sops secret `yubikey/<user>/<key>/luks-secret` (the FIDO2-derived
#   LUKS passphrase) plus the shared `luks-passphrase` (the passphrase typed
#   at disko install time, needed to authorize new keyslots).
#
# The module then propagates everything declaratively (`just apply`), without
# ever plugging the key on the target hosts:
#
# - **login / sudo / greeter**: pam_u2f as a password *alternative*
#   (`sufficient`): touching the key logs in, the sops password remains the
#   automatic fallback. One credential is valid fleet-wide thanks to the
#   fixed origin (`pam://<network.domain>`).
# - **encrypted hosts**: a oneshot service self-enrolls each declared key in
#   every disko-declared LUKS2 header (keyslot + `systemd-fido2` token, the
#   exact format `systemd-cryptenroll` writes) and prunes revoked ones. The
#   physical key is only ever needed at boot to unlock the disk.
#
# :::note[Zero configuration]
# Enabled by default, but fully inert until the registry file exists.
# LUKS support keys on the LUKS volumes found in the host disko config
# (`usr/machines/<host>/disko.nix`, imported at runtime).
# :::
#
# :::caution[No lockout by design]
# The install passphrase keyslot and the sops session passwords are never
# touched: losing a key at worst falls back to passphrase/password. This holds
# at boot too: the FIDO2 attempt runs in a unit of its own that is allowed to
# fail, so an unusable, untouched or absent key always ends on the passphrase
# prompt — see the comment on the initrd block below.
# :::
#
# :::caution[The boot touch cannot be waived]
# YubiKeys enforce user presence for the `hmac-secret` extension: an assertion
# requesting `up=false` is refused with `FIDO_ERR_UP_REQUIRED` before the
# credential is even matched. The touch is a hardware rule, not a token
# setting, and no header flag can lift it. Unattended unlock (gateways,
# headless hosts) is a TPM2 job (`systemd-cryptenroll --tpm2-device=auto`),
# which coexists with these FIDO2 keyslots in the same LUKS header.
# :::
#
# :::caution[GNOME keyring stays locked on a key login]
# `sufficient` short-circuits the auth stack: touching the key ends it before
# `pam_gnome_keyring` runs, so the daemon starts with no password and GNOME
# asks for the keyring one at session start (GNOME Online Accounts and
# evolution-data-server request the secret service immediately). A password
# login is unaffected. Remedy on the desktop hosts concerned: give the *login*
# keyring an empty password in Seahorse — it then unlocks by itself, secrets
# landing in clear text on an already LUKS-encrypted disk. See
# `doc/admin-guide/operate/yubikey`.
# :::

{
  lib,
  config,
  pkgs,
  utils,
  host,
  network,
  workDir,
  ...
}:
let
  cfg = config.darkone.system.yubikey;

  # Public registry written by `just yubikey` (consumer workspace, committed).
  # Missing file = module inert: safe default for fresh workspaces.
  registryFile = workDir + "/usr/secrets/yubikeys.json";
  hasRegistry = builtins.pathExists registryFile;
  registry = if hasRegistry then builtins.fromJSON (builtins.readFile registryFile) else { };

  # PAM only wires keys of users declared on this host; LUKS enrollment below
  # deliberately takes the FULL registry: any enrolled key unlocks any
  # encrypted host of the fleet (disk unlock is an admin capability, not a
  # session credential).
  pamRegistry = lib.filterAttrs (login: _: lib.elem login host.users) registry;

  # pam_u2f authfile, one line per user: `login:cred[:cred...]`. The pamu2fcfg
  # chunks are public key material.
  u2fMappings = lib.concatMapStrings (
    login:
    let
      creds = lib.filter (c: c != "") (lib.mapAttrsToList (_: k: k.pam or "") pamRegistry.${login});
    in
    lib.optionalString (creds != [ ]) "${lib.concatStringsSep ":" ([ login ] ++ creds)}\n"
  ) (lib.attrNames pamRegistry);

  # (user, key) pairs carrying a FIDO2 hmac-secret credential (LUKS-capable).
  luksKeys = lib.concatLists (
    lib.mapAttrsToList (
      login: keys:
      lib.mapAttrsToList (kname: k: {
        inherit (k) credId salt;
        owner = "${login}/${kname}";
        secret = "yubikey/${login}/${kname}/luks-secret";
      }) (lib.filterAttrs (_: k: (k.credId or "") != "") keys)
    ) registry
  );

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

  luksActive = cfg.luks.enable && luksNames != [ ] && luksKeys != [ ];

  # Volumes the FIDO2 unlock unit below can rebuild a crypttab line for. A key
  # file or a detached header means fields it does not carry, and a wrong
  # `systemd-cryptsetup attach` would fail on every boot for nothing: those
  # volumes keep the passphrase path alone.
  unlockable = lib.filter (
    n:
    let
      d = config.boot.initrd.luks.devices.${n};
    in
    d.keyFile == null && d.header == null
  ) luksNames;

  # Everything the enroll service needs, public data only (credential ids,
  # salts, device names, sops paths): safe in the store.
  enrollData = pkgs.writeText "yubikey-luks-enroll.json" (
    builtins.toJSON {
      devices = map (n: config.boot.initrd.luks.devices.${n}.device) luksNames;
      keys = map (k: {
        inherit (k) credId salt owner;
        secret = config.sops.secrets.${k.secret}.path;
      }) luksKeys;
    }
  );
in
{
  options = {
    darkone.system.yubikey.enable = lib.mkOption {
      type = lib.types.bool;
      default = hasRegistry;
      description = "YubiKey authentication (default: enabled when usr/secrets/yubikeys.json exists)";
    };

    darkone.system.yubikey.origin = lib.mkOption {
      type = lib.types.str;
      default = "pam://${network.domain}";
      description = "Fixed pam_u2f origin/appid: one enrollment is valid fleet-wide";
    };

    darkone.system.yubikey.luks.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "FIDO2 unlock of the host LUKS volumes (inert without disko LUKS + enrolled keys)";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [

      #========================================================================
      # PAM: the key touch replaces the password (password stays as fallback)
      #========================================================================

      {
        security.pam.u2f = {
          enable = true;

          # `sufficient` + `nouserok`: a key logs in with a touch, anything else
          # (no key, no credential, no registry line) falls back to the password.
          control = "sufficient";
          settings = {
            authfile = "/etc/u2f_mappings";

            # Both must match the values used by pamu2fcfg at enrollment;
            # defaults derive from the local hostname and would break roaming.
            origin = cfg.origin;
            appid = cfg.origin;
            cue = true;
            nouserok = true;
          };
        };

        # Central credential map, built from the registry for this host's users.
        environment.etc.u2f_mappings.text = u2fMappings;

        # Enrollment & diagnostic tooling (pamu2fcfg, fido2-*, ykman).
        environment.systemPackages = [
          pkgs.pam_u2f
          pkgs.libfido2
          pkgs.yubikey-manager
        ];
        services.udev.packages = [
          pkgs.libfido2
          pkgs.yubikey-personalization
        ];

        # libfido2 ships 70-u2f.rules, whose 101 rules each end with
        # `TAG+="uaccess", GROUP="plugdev"`. `plugdev` is a Debian convention
        # NixOS never creates, so udev logs one "Failed to resolve group" warning
        # per rule on every reload. Purely cosmetic — access is actually granted
        # by the uaccess tag, which makes logind set an ACL for the active local
        # session; the group is only the legacy fallback for non-systemd
        # distributions. Declaring it empty just silences the noise.
        users.groups.plugdev = { };
      }

      #========================================================================
      # LUKS: declarative FIDO2 enrollment of every declared (user, key)
      #========================================================================

      (lib.mkIf luksActive {

        # systemd initrd unlocks the FIDO2 keyslots; USB HID modules make the
        # key reachable before cryptsetup runs.
        boot.initrd.systemd.enable = true;
        boot.initrd.availableKernelModules = [
          "usbhid"
          "hid_generic"
        ];

        # `fido2-device=auto` is deliberately NOT put in the crypttab entry,
        # and the token attempt is not dropped either. Both extremes are wrong:
        #
        # - with the option, a token plugged in and left untouched makes
        #   systemd-cryptsetup exit 1 instead of falling back to the
        #   passphrase — no prompt, on the console or over ssh, and the boot
        #   dies in the initrd (measured on systemd 261:
        #   `FIDO_ERR_OPERATION_DENIED` after ~29s of unanswered user presence).
        #   A power cut on a headless host with a key left in its port was
        #   enough to strand it;
        # - without it, the token is tried only if a FIDO2 device is
        #   *already* enumerated when the unit runs — nothing waits for one.
        #   At cold boot `systemd-cryptsetup@` starts ~1.2s before `hidraw0`
        #   exists, so the key is never seen and the enrolled keyslots unlock
        #   nothing. Measured both ways: no FIDO2 line at all on a cold boot,
        #   but "Asking FIDO2 token for authentication" when the same unit
        #   runs 30s in, on a key plugged all along.
        #
        # What `fido2-device=` really buys is the *wait* (`token-timeout=`).
        # So the attempt lives in a unit of its own, ordered `Before=` the real
        # `systemd-cryptsetup@` one and only `Wants=`-linked to it: it is
        # allowed to fail, and its failure changes nothing. Three cases, all
        # ending on an unlock or a prompt:
        #
        # - key touched: volume open, the real unit logs "Volume data already
        #   active" and succeeds;
        # - key plugged, never touched: libfido2 gives up after ~30s, this unit
        #   fails, the real unit prompts for the passphrase;
        # - no key: `token-timeout` elapses (~6s measured) and this unit puts
        #   up the passphrase prompt itself — one prompt, `NotAfter=0`, served
        #   in parallel by the tty1 agent and by `just enter` over ssh. The
        #   real unit then finds the volume open.
        #
        # A key is a convenience. It must never become the only way in — which
        # is what the "No lockout by design" note above promises.
        boot.initrd.systemd.services = lib.listToAttrs (
          map (name: {
            name = "yubikey-luks-unlock-${name}";
            value =
              let
                dev = config.boot.initrd.luks.devices.${name};
                cryptsetupUnit = "systemd-cryptsetup@${utils.escapeSystemdPath name}.service";
                sourceUnit = "${utils.escapeSystemdPath dev.device}.device";

                # Same options as the crypttab line nixpkgs generates for this
                # volume, plus the token. Volumes with a key file or a detached
                # header are filtered out of `unlockable`: their line carries
                # fields this rebuild does not reproduce.
                opts = lib.concatStringsSep "," (
                  [
                    "fido2-device=auto"

                    # Only bounds the wait for a token to *appear*; the
                    # unattended-key case is bounded by libfido2, not here.
                    # Paid in full on every boot without a key, hence short.
                    "token-timeout=5s"
                  ]
                  ++ lib.optional dev.allowDiscards "discard"
                  ++ lib.optionals dev.bypassWorkqueues [
                    "no-read-workqueue"
                    "no-write-workqueue"
                  ]
                  ++ dev.crypttabExtraOpts
                );
              in
              {
                description = "FIDO2 unlock attempt for LUKS volume ${name}";
                wantedBy = [ cryptsetupUnit ];
                requires = [ sourceUnit ];
                after = [ sourceUnit ];
                before = [
                  cryptsetupUnit
                  "initrd-switch-root.target"
                  "shutdown.target"
                ];
                conflicts = [
                  "initrd-switch-root.target"
                  "shutdown.target"
                ];
                unitConfig.DefaultDependencies = false;
                serviceConfig = {
                  Type = "oneshot";

                  # No ExecStop counterpart on purpose: closing the volume is
                  # the real unit's business, whoever opened it.
                  RemainAfterExit = true;

                  # `infinity`, like `systemd-cryptsetup@.service` upstream.
                  # Past the token attempt this unit is the one holding the
                  # passphrase prompt (see the third case above), and a prompt
                  # cut short mid-typing is worse than no bound at all: the
                  # FIDO2 leg is already bounded by libfido2 (~30s, measured)
                  # and by `token-timeout` when no key shows up.
                  TimeoutSec = "infinity";

                  # `-`: an untouched or absent key is the expected outcome,
                  # not an incident. Without it the failure survives
                  # switch-root as a `not-found failed` ghost in stage 2,
                  # where the unit no longer exists — enough to spoil the
                  # `systemctl --failed` health check on every such boot. The
                  # journal keeps the FIDO2 detail either way.
                  ExecStart = "-/bin/systemd-cryptsetup attach ${name} ${dev.device} - ${opts}";
                };
              };
          }) unlockable
        );

        # Derived secrets (one per enrolled key) + the shared passphrase that
        # authorizes keyslot management. All created by `just yubikey`.
        # restartUnits: a changed credential converges at the same apply
        # instead of waiting for the next boot.
        sops.secrets =
          lib.listToAttrs (
            map (k: {
              name = k.secret;
              value.restartUnits = [ "yubikey-luks-enroll.service" ];
            }) luksKeys
          )
          // {
            luks-passphrase.restartUnits = [ "yubikey-luks-enroll.service" ];
          };

        # Idempotent sync of the LUKS2 headers with the declared credentials:
        # adds missing (keyslot + systemd-fido2 token), prunes revoked ones.
        # Only credentials recorded in the local ledger are ever pruned, so
        # out-of-band enrollments (manual systemd-cryptenroll) survive; the
        # passphrase keyslot is never touched. Any failure is logged and
        # skipped: this unit must never block a deployment or a boot.
        #
        # An enrollment is two operations (keyslot, then token) and being
        # interrupted between them strands the keyslot, so the unit rolls its
        # own back on the way out and adopts any it finds on the next run.
        systemd.services.yubikey-luks-enroll = {
          description = "Sync FIDO2 credentials into LUKS headers";
          wantedBy = [ "multi-user.target" ];

          # The enrollments below are authorized by the shared passphrase, so
          # a (re)converged passphrase keyslot must re-trigger this unit:
          # partOf propagates every luks-passphrase-sync restart (rotation,
          # bootstrap after reinstall) here. Dangling when the luks module is
          # inert, which systemd ignores.
          partOf = [ "luks-passphrase-sync.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;

            # argon2 costs ~10s per keyslot, so a fleet of eight credentials
            # already exceeds systemd's 90s default: the unit would be killed
            # mid-enrollment, which is precisely what strands a keyslot.
            TimeoutStartSec = "30min";
          };
          script = ''
            set -euo pipefail
            jq=${pkgs.jq}/bin/jq
            cs=${pkgs.cryptsetup}/bin/cryptsetup
            grep=${pkgs.gnugrep}/bin/grep
            awk=${pkgs.gawk}/bin/awk
            data=${enrollData}
            pass=${config.sops.secrets.luks-passphrase.path}

            # Slots of the managed passphrases, as recorded by
            # luks-passphrase-sync. Needed to tell an orphan keyslot from a
            # legitimately token-less one.
            passledger=/var/lib/luks-passphrase/ledger

            # A keyslot exists from `luksAddKey` until `token import` names it.
            # Being stopped in that window is not hypothetical: partOf ties
            # this unit to luks-passphrase-sync, so a passphrase converging
            # mid-enrollment (every fresh install does it) sends a TERM here.
            # Without this the keyslot survives with nothing pointing at it —
            # invisible to systemd, and unreachable by the revocation loop
            # below, which walks tokens to find the slots to kill.
            pending=""
            pendingdev=""
            cleanup() {
              [ -n "$pending" ] || return 0
              $cs luksKillSlot -q --key-file="$pass" "$pendingdev" "$pending" \
                && echo "rolled back incomplete keyslot $pending on $pendingdev" \
                || echo "could not roll back keyslot $pending on $pendingdev"
            }
            trap cleanup EXIT TERM INT

            # Membership in a jq-produced list. jq separates with newlines,
            # so the caller must join with spaces first: a `case` glob on a
            # newline-separated list silently never matches, and a keyslot
            # inventory that matches nothing is a fleet-wide revocation.
            in_list() {
              case " $2 " in
                *" $1 "*) return 0 ;;
              esac
              return 1
            }

            # Ledger of the credentials this service enrolled (prune scope).
            state=/var/lib/yubikey-luks/managed
            ${pkgs.coreutils}/bin/mkdir -p /var/lib/yubikey-luks
            ${pkgs.coreutils}/bin/touch "$state"

            if [ ! -s "$pass" ]; then
              echo "luks-passphrase secret is empty, nothing done"
              exit 0
            fi
            declared=$($jq -r '.keys[].credId' "$data")

            for dev in $($jq -r '.devices[]' "$data"); do
              if [ ! -e "$dev" ]; then
                echo "device $dev not found, skipped"
                continue
              fi
              if ! dump=$($cs luksDump --dump-json-metadata "$dev" 2>/dev/null); then
                echo "$dev is not a LUKS2 device, skipped"
                continue
              fi
              present=$(printf '%s' "$dump" | $jq -r '
                .keyslots as $slots
                | .tokens[]? | select(.type == "systemd-fido2")
                | select([.keyslots[]? | select($slots[.] != null)] | length > 0)
                | ."fido2-credential"')

              # Orphan suspects: keyslots claimed by no token and by neither
              # managed passphrase. Empty in steady state, so what follows
              # costs nothing on a healthy header. Without the passphrase
              # ledger their slots would land here, so give up rather than
              # spend an argon2 derivation per credential proving they do not
              # belong to a YubiKey.
              orphans=""
              if [ -r "$passledger" ]; then
                claimed=$(printf '%s' "$dump" | $jq -r '[.tokens[]?.keyslots[]?] | join(" ")')
                claimed="$claimed $($awk -v d="$dev" '$2 == d {print $4}' "$passledger" | ${pkgs.coreutils}/bin/tr '\n' ' ')"
                for s in $(printf '%s' "$dump" | $jq -r '.keyslots | keys[]'); do
                  in_list "$s" "$claimed" || orphans="$orphans $s"
                done
                [ -z "$orphans" ] || echo "keyslots claimed by nothing on $dev:$orphans"
              fi

              # Ownership of an orphan slot is never assumed: the credential's
              # own secret has to open it. That proof is what keeps a manual
              # `systemd-cryptenroll` — equally token-less from here — safe.
              claim_orphan() {
                local o
                for o in $orphans; do
                  if $cs open --test-passphrase --key-slot "$o" \
                      --key-file="$1" "$dev" >/dev/null 2>&1; then
                    printf %s "$o"
                    return 0
                  fi
                done
                return 1
              }
              drop_orphan() {
                local keep="" o
                for o in $orphans; do
                  [ "$o" = "$1" ] || keep="$keep $o"
                done
                orphans=$keep
              }

              # Enroll every declared credential missing from this header.
              n=$($jq '.keys | length' "$data")
              for i in $(${pkgs.coreutils}/bin/seq 0 $((n - 1))); do
                cred=$($jq -r ".keys[$i].credId" "$data")
                salt=$($jq -r ".keys[$i].salt" "$data")
                secret=$($jq -r ".keys[$i].secret" "$data")
                owner=$($jq -r ".keys[$i].owner" "$data")
                if printf '%s\n' "$present" | $grep -qxF "$cred"; then

                  # Enrolled AND holding an orphan slot: the interrupted add
                  # was retried on the next run, so this one is a duplicate —
                  # a live secret nothing tracks, and a slot out of the 32.
                  if [ -n "$orphans" ] && [ -s "$secret" ] && dup=$(claim_orphan "$secret"); then
                    drop_orphan "$dup"

                    # Removing a keyslot is the one irreversible act here, so
                    # it happens only against proof that the credential keeps
                    # another one its token points at. A miscomputed orphan
                    # list would otherwise revoke the whole fleet, one key at
                    # a time — which is exactly what it once did.
                    kept=$(printf '%s' "$dump" | $jq -r --arg c "$cred" \
                      '[.tokens[]? | select(."fido2-credential" == $c) | .keyslots[]?] | join(" ")')
                    if [ -z "$kept" ] || in_list "$dup" "$kept"; then
                      echo "keeping keyslot $dup on $dev: $owner has no other enrollment"
                    else
                      $cs luksKillSlot -q --key-file="$pass" "$dev" "$dup" \
                        && echo "removed duplicate keyslot $dup on $dev for $owner" \
                        || echo "could not remove duplicate keyslot $dup on $dev"
                    fi
                  fi
                  continue
                fi
                if [ ! -s "$secret" ]; then
                  echo "secret of $owner is empty, skipped"
                  continue
                fi

                # A token left pointing at a dead keyslot (cryptsetup empties
                # its keyslot list) is what `present` above now ignores; drop
                # it here so the re-enrollment does not stack a second token
                # for the same credential.
                for tid in $(printf '%s' "$dump" | $jq -r --arg c "$cred" \
                    '.tokens | to_entries[] | select(.value."fido2-credential" == $c) | .key'); do
                  $cs token remove --token-id "$tid" "$dev" \
                    && echo "dropped stale token $tid on $dev for $owner"
                done

                # An earlier run may have added the keyslot and died before
                # naming it: adopt it, rather than pay a second slot and a
                # second derivation for a secret already in the header.
                if slot=$(claim_orphan "$secret"); then
                  drop_orphan "$slot"
                  echo "adopting stranded keyslot $slot on $dev for $owner"
                else

                  # The derived secret (base64 of the hmac-secret output) is the
                  # keyslot passphrase, exactly as systemd-cryptenroll stores it.
                  before=$(printf '%s' "$dump" | $jq -r '.keyslots | keys | join(" ")')
                  if ! $cs luksAddKey --key-file="$pass" "$dev" "$secret"; then
                    echo "luksAddKey failed on $dev for $owner (wrong luks-passphrase?), skipped"
                    continue
                  fi
                  dump=$($cs luksDump --dump-json-metadata "$dev")
                  slot=""
                  for s in $(printf '%s' "$dump" | $jq -r '.keyslots | keys[]'); do
                    in_list "$s" "$before" || slot=$s
                  done
                  pending=$slot
                  pendingdev=$dev
                fi

                # `fido2-up-required` is not a policy we get to choose: YubiKeys
                # reject every hmac-secret assertion made without user presence
                # (FIDO_ERR_UP_REQUIRED, raised before credential matching), so
                # the boot touch is enforced by the key itself. systemd agrees —
                # cryptenroll silently re-enables the flag on such devices, and
                # cryptsetup retries with presence when a token claims false.
                # An unattended unlock is a TPM2 job, not a FIDO2 one.
                $jq -n --arg slot "$slot" --arg cred "$cred" --arg salt "$salt" \
                  '{type: "systemd-fido2", keyslots: [$slot],
                    "fido2-credential": $cred, "fido2-salt": $salt,
                    "fido2-rp": "io.systemd.cryptsetup",
                    "fido2-clientPin-required": false,
                    "fido2-up-required": true,
                    "fido2-uv-required": false}' \
                  | $cs token import "$dev"

                # The keyslot is named: it can no longer be stranded.
                pending=""
                echo "$cred" >> "$state"
                echo "enrolled $owner on $dev (slot $slot)"
              done

              # Prune ledger credentials that are no longer declared: kill the
              # token keyslots first, then drop the token itself.
              while read -r cred; do
                [ -n "$cred" ] || continue
                if printf '%s\n' "$declared" | $grep -qxF "$cred"; then
                  continue
                fi
                dump=$($cs luksDump --dump-json-metadata "$dev")
                tid=$(printf '%s' "$dump" | $jq -r --arg c "$cred" \
                  '.tokens | to_entries[] | select(.value."fido2-credential" == $c) | .key')
                [ -n "$tid" ] || continue
                for slot in $(printf '%s' "$dump" | $jq -r ".tokens.\"$tid\".keyslots[]"); do
                  $cs luksKillSlot -q --key-file="$pass" "$dev" "$slot"
                done
                $cs token remove --token-id "$tid" "$dev"
                echo "revoked credential $cred on $dev"
              done < "$state"
            done

            # Refresh the ledger: keep only still-declared credentials.
            tmp=$(${pkgs.coreutils}/bin/mktemp)
            printf '%s\n' "$declared" > "$tmp"
            $grep -xFf "$tmp" "$state" > "$state.new" || true
            ${pkgs.coreutils}/bin/sort -u "$state.new" > "$state"
            ${pkgs.coreutils}/bin/rm -f "$state.new" "$tmp"
          '';
        };
      })
    ]
  );
}
