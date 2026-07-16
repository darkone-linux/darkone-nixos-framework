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
# touched: losing a key at worst falls back to passphrase/password.
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
      }

      #========================================================================
      # LUKS: declarative FIDO2 enrollment of every declared (user, key)
      #========================================================================

      (lib.mkIf luksActive {

        # systemd initrd unlocks FIDO2 tokens (`fido2-device=auto`); USB HID
        # modules make the key reachable before cryptsetup runs.
        boot.initrd.systemd.enable = true;
        boot.initrd.availableKernelModules = [
          "usbhid"
          "hid_generic"
        ];
        boot.initrd.luks.devices = lib.genAttrs luksNames (_: {
          crypttabExtraOpts = [ "fido2-device=auto" ];
        });

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
          };
          script = ''
            set -euo pipefail
            jq=${pkgs.jq}/bin/jq
            cs=${pkgs.cryptsetup}/bin/cryptsetup
            grep=${pkgs.gnugrep}/bin/grep
            data=${enrollData}
            pass=${config.sops.secrets.luks-passphrase.path}

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
              present=$(printf '%s' "$dump" \
                | $jq -r '.tokens[]? | select(.type == "systemd-fido2") | ."fido2-credential"')

              # Enroll every declared credential missing from this header.
              n=$($jq '.keys | length' "$data")
              for i in $(${pkgs.coreutils}/bin/seq 0 $((n - 1))); do
                cred=$($jq -r ".keys[$i].credId" "$data")
                salt=$($jq -r ".keys[$i].salt" "$data")
                secret=$($jq -r ".keys[$i].secret" "$data")
                owner=$($jq -r ".keys[$i].owner" "$data")
                if printf '%s\n' "$present" | $grep -qxF "$cred"; then
                  continue
                fi
                if [ ! -s "$secret" ]; then
                  echo "secret of $owner is empty, skipped"
                  continue
                fi

                # The derived secret (base64 of the hmac-secret output) is the
                # keyslot passphrase, exactly as systemd-cryptenroll stores it.
                before=$(printf '%s' "$dump" | $jq -r '.keyslots | keys[]')
                if ! $cs luksAddKey --key-file="$pass" "$dev" "$secret"; then
                  echo "luksAddKey failed on $dev for $owner (wrong luks-passphrase?), skipped"
                  continue
                fi
                dump=$($cs luksDump --dump-json-metadata "$dev")
                slot=""
                for s in $(printf '%s' "$dump" | $jq -r '.keyslots | keys[]'); do
                  case " $before " in
                    *" $s "*) ;;
                    *) slot=$s ;;
                  esac
                done
                $jq -n --arg slot "$slot" --arg cred "$cred" --arg salt "$salt" \
                  '{type: "systemd-fido2", keyslots: [$slot],
                    "fido2-credential": $cred, "fido2-salt": $salt,
                    "fido2-rp": "io.systemd.cryptsetup",
                    "fido2-clientPin-required": false,
                    "fido2-up-required": true,
                    "fido2-uv-required": false}' \
                  | $cs token import "$dev"
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
