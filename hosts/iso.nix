# DNF ISO image for fast workstation installs.
#
# -> Build the image:
# nix build .#nixosConfigurations.iso-x86_64-linux.config.system.build.isoImage
#
# -> Install with the image:
# dnf-netinfo # IP + MAC to use, network cards and disks (names for
#             # wan.interface, lan.interfaces, disko.devices); also printed
#             # on the console at boot
# just full-install my-host nixos 10.1.3.211 # Install "my-host"
#
# -> Generic image only, menu on tty1:
# 1) darkone new # this machine becomes the admin host (--answers: scripted)
# 2) add this machine to an existing network: dnf-pair, any console too
#    (pairing code, address, cards, disks)
# 3) shell
#
# -> Pairing (generic image, no admin key baked in):
# - `dnf-pair.service` owns the code `PPPPPP-FFFF`: `PPPPPP` is the `nixos`
#   password, 10 min, a new one after (6 at most); `FFFF` comes from the
#   ed25519 host key (`just/scripts/pair-fingerprint.sh`);
# - paired once `~nixos/.ssh/authorized_keys` holds a key: the password goes
#   back to empty, which sshd refuses. State: `/run/dnf-pair/state`;
# - `systemctl stop dnf-pair` locks too; a password set by hand is left alone.

{
  config,
  modulesPath,
  stdenv,
  lib,
  pkgs,
  workDir ? null,
  installer ? null,
  ...
}:
let

  # Standalone image (release download): no admin key baked in. The installer's
  # `nixos` account has an empty password, which sshd refuses: the pairing
  # code, or one `passwd`, lets the key in. Empty for a consumer ISO, whose
  # drvPath stays put.
  keylessHint = lib.optionalString (workDir == null) (
    "\n"
    + (
      if installer != null then
        "printf '\\nNo admin key in this image. To add this machine to a network: dnf-pair\\n'"
      else
        ''printf '\nNo admin key in this image. Set a password with passwd, then from\nthe admin host: sudo -i -u nix ssh-copy-id nixos@%s\n' "$addr"''
    )
  );

  # `~nixos/.ssh/authorized_keys`: where the admin host pushes its key, what
  # pairing waits for. sshd reads it (`AuthorizedKeysFile %h/.ssh/…`).
  pairKeys = "/home/nixos/.ssh/authorized_keys";
  pairState = "/run/dnf-pair/state";

  # FFFF of the pairing code; the admin host runs the same file.
  pairFingerprint = pkgs.writeShellApplication {
    name = "dnf-pair-fingerprint";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../just/scripts/pair-fingerprint.sh;
  };

  # Owner of the pairing code: one per machine, whichever console shows it.
  # Root, started on demand by `dnf-pair`. Expiry on `/proc/uptime`: NTP
  # moves the wall clock right after the first lease.
  pairService = ''
    sshKeygen=${config.services.openssh.package}/bin/ssh-keygen
    state=${pairState}
    keys=${pairKeys}
    fingerprint="$(${lib.getExe pairFingerprint} /etc/ssh/ssh_host_ed25519_key.pub)"
    ours=""

    # Atomic: a console may read it at any time.
    publish() {
      printf 'status=%s\ncode=%s\nexpires=%s\n' "$1" "''${2:-}" "''${3:-}" > "$state.tmp"
      ${pkgs.coreutils}/bin/mv -f "$state.tmp" "$state"
    }
    now() {
      local up _
      read -r up _ < /proc/uptime
      echo "''${up%.*}"
    }

    # A complete key, not an append in progress.
    paired() { [ -s "$keys" ] && "$sshKeygen" -l -f "$keys" > /dev/null 2>&1; }
    hash() {
      local user h _
      while IFS=: read -r user h _; do
        if [ "$user" = nixos ]; then
          echo "$h"
        fi
      done < /etc/shadow
    }

    # Back to the empty password of the boot, refused by sshd. A password the
    # operator set meanwhile (`passwd`) is left alone.
    lock() {
      if [ -n "$ours" ] && [ "$(hash)" = "$ours" ]; then
        ${pkgs.shadow}/bin/passwd -d nixos > /dev/null
      fi
      ours=""
    }
    finish() {
      lock
      if paired; then
        publish paired
      else
        publish "$1"
      fi
      exit 0
    }
    trap 'finish stopped' TERM INT

    if paired; then
      finish paired
    fi
    for round in 1 2 3 4 5 6; do

      # Uniform over 6 digits: `SRANDOM` (getrandom), rejection above the
      # largest multiple of 10^6 under 2^32.
      while n=$SRANDOM; [ "$n" -ge 4294000000 ]; do :; done
      pin="$(printf '%06d' "$((n % 1000000))")"
      printf 'nixos:%s\n' "$pin" | ${pkgs.shadow}/bin/chpasswd
      ours="$(hash)"
      expires=$(($(now) + 600))
      publish active "$pin-$fingerprint" "$expires"
      echo "Pairing code $round of 6 drawn, valid 10 min."

      while [ "$(now)" -lt "$expires" ]; do
        if paired; then
          echo "Admin key in place: paired, password locked."
          finish paired
        fi
        if [ "$(hash)" != "$ours" ]; then
          echo "Password changed by hand: pairing stopped, password left alone."
          ours=""
          finish manual
        fi
        ${pkgs.coreutils}/bin/sleep 1
      done
    done
    echo "Six codes expired: pairing closed, password locked."
    finish closed
  '';

  # `dnf-pair`: starts the code's owner, prints the code with the address,
  # cards and disks, waits for the admin host. As root: the state holds the
  # password. Ctrl-C leaves the code valid.
  pair = pkgs.writeShellApplication {
    name = "dnf-pair";
    runtimeInputs = [
      netinfo
      pkgs.coreutils
      pkgs.iproute2
      config.systemd.package
    ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        exec ${config.security.wrapperDir}/sudo "$0" "$@"
      fi
      state=${pairState}
      magenta=$'\e[1;35m'
      reset=$'\e[0m'

      load() {
        local k v
        status=""
        code=""
        expires=0
        if [ -f "$state" ]; then
          while IFS='=' read -r k v; do
            case "$k" in
              status) status="$v" ;;
              code) code="$v" ;;
              expires) expires="$v" ;;
            esac
          done < "$state"
        fi
      }
      minutes() {
        local up _
        read -r up _ < /proc/uptime
        echo $(((expires - ''${up%.*} + 59) / 60))
      }

      # Already running (another console): the same code. Stopped: a new one.
      systemctl start dnf-pair.service

      # The route may be gone since boot: a placeholder, not an exit.
      route="$(ip -4 -o route get 1.1.1.1 2>/dev/null || true)"
      addr='<this-ip>'
      if [[ "$route" == *" src "* ]]; then
        addr="''${route#* src }"
        addr="''${addr%% *}"
      fi

      trap 'printf "\nBack to the shell. Code still valid, shown again by: dnf-pair\n"; exit 0' INT
      shown=""
      for _ in $(seq 10); do
        load
        if [ -n "$status" ]; then
          break
        fi
        sleep 1
      done
      if [ -z "$status" ]; then
        echo "dnf-pair.service wrote no code: journalctl -u dnf-pair" >&2
        exit 1
      fi
      if [ "$status" = active ]; then
        printf '\n- IP: %s%s%s\n' "$magenta" "$addr" "$reset"
        dnf-netinfo --list
        printf '\nOn the admin host: just full-install <host> nixos %s\n' "$addr"
        printf 'and type this code when it asks (Ctrl-C: shell, the code stays valid).\n'
      fi

      # `Pairing code:` stays as is: the installer test reads it on ttyS0.
      while true; do
        case "$status" in
          active)
            if [ "$code" != "$shown" ]; then
              printf '\nPairing code: %s%s%s  (%s min, a new one after)\n' \
                "$magenta" "$code" "$reset" "$(minutes)"
              shown="$code"
            fi
            ;;
          paired)
            printf '\nPaired: the admin host key is in place, password locked.\n'
            exit 0
            ;;
          closed)
            printf '\nPairing closed: no admin host came. A new code: dnf-pair\n'
            exit 0
            ;;
          manual)
            printf '\nPassword set by hand: pairing stopped, the password stays.\n'
            exit 0
            ;;
          *)
            printf '\nPairing stopped. A new code: dnf-pair\n'
            exit 0
            ;;
        esac
        sleep 1
        load
      done
    '';
  };

  # What the operator copies into etc/config.yaml: IP + MAC of the interface
  # holding the route (what `just full-install` reaches), then the network
  # cards and disks. `--list`: the cards and disks only. `ip route get`
  # resolves only, sends no packet.
  netinfo = pkgs.writeShellApplication {
    name = "dnf-netinfo";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnused
      pkgs.iproute2
      pkgs.util-linux
    ];
    text = ''
      cyan=$'\e[1;36m'
      magenta=$'\e[1;35m'
      reset=$'\e[0m'

      # Interface holding the route: marked as the future WAN of a gateway.
      dev=""

      # Physical cards only: virtual ones (lo, bridge, veth, tun) have no `device`.
      cards() {
        local n name link addr note
        printf '\nNetwork cards (wan.interface, lan.interfaces):\n'
        {
          printf 'NAME\tMAC\tLINK\tIPV4\tNOTE\n'
          for n in /sys/class/net/*; do
            if [ ! -e "$n/device" ]; then
              continue
            fi
            name="''${n##*/}"

            # `carrier` is unreadable on a card that is down.
            link=down
            if [ "$(cat "$n/carrier" 2>/dev/null || true)" = 1 ]; then
              link=up
            fi
            addr="$(ip -4 -o addr show dev "$name" scope global | awk '{ print $4 }' | paste -sd, -)"
            note=""
            if [ -e "$n/wireless" ]; then
              note="wifi"
            fi
            if [ "$name" = "$dev" ]; then
              note="''${note:+$note, }default route (WAN)"
            fi
            printf '%s\t%s\t%s\t%s\t%s\n' \
              "$name" "$(cat "$n/address")" "$link" "''${addr:--}" "$note"
          done
        } | column -t -s $'\t' | sed 's/^/  /; s/ *$//'
      }

      # Kernel name of the disk holding the booted medium (/iso, iso9660): never
      # an install target. Empty with `copytoram` or an optical drive.
      media_disk() {
        local src parent
        src="$(findmnt -n -o SOURCE /iso 2>/dev/null || true)"
        if [ ! -b "$src" ]; then
          return 0
        fi
        src="$(readlink -f "$src")"

        # A partition has a parent; a whole-disk medium (ISO hybrid) has none.
        parent="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n 1 || true)"
        basename "''${parent:-$src}"
      }

      # Most readable stable link of a disk. `ata-`/`nvme-`/`usb-` carry model
      # and serial, as on the drive label: preferred over `wwn-` and `eui.`
      # (unique, unreadable). `scsi-` between. Empty when no link exists.
      disk_link() {
        local l base rank best="" best_rank=9
        for l in /dev/disk/by-id/*; do
          base="''${l##*/}"

          # Whole disks only, and names `disko.devices` accepts.
          case "$base" in
            *-part*) continue ;;
          esac
          if [ "$(readlink -f "$l")" != "/dev/$1" ] || [[ ! "$base" =~ ^[A-Za-z0-9._:+-]+$ ]]; then
            continue
          fi
          case "$base" in
            wwn-* | *eui.*) rank=3 ;;
            scsi-*) rank=2 ;;
            *) rank=1 ;;
          esac
          if [ "$rank" -lt "$best_rank" ]; then
            best="$l"
            best_rank="$rank"
          fi
        done
        printf '%s' "$best"
      }

      # Disks with hardware behind them: loop, zram, md, dm have no `device`.
      disks() {
        local media n name sectors link model note found=0
        media="$(media_disk)"
        printf '\nDisks (disko.devices), installation medium left out:\n'
        for n in /sys/block/*; do
          name="''${n##*/}"
          sectors="$(cat "$n/size" 2>/dev/null || echo 0)"

          # Optical drives, eMMC boot/RPMB areas and empty card readers are no target.
          case "$name" in
            sr* | mmcblk*boot* | mmcblk*rpmb) continue ;;
          esac
          if [ ! -e "$n/device" ] || [ "$sectors" -eq 0 ] || [ "$name" = "$media" ]; then
            continue
          fi
          found=1
          link="$(disk_link "$name")"
          model="$(awk '{ $1 = $1 } 1' "$n/device/model" 2>/dev/null || true)"
          note="$name"
          if [ -z "$link" ]; then
            note="$name, no by-id link"
          fi
          printf '  %s\n' "''${link:-/dev/$name}"
          printf '      %s  %s  [%s]\n' \
            "$(numfmt --to=iec $((sectors * 512)))" "''${model:--}" "$note"
        done
        if [ "$found" -eq 0 ]; then
          printf '  none found\n'
        fi
      }

      # `--list`: the two tables only, for the assistant.
      if [ "''${1:-}" = "--list" ]; then
        dev="$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' || true)"
        cards
        disks
        exit 0
      fi

      # `--welcome`: console login banner, replaces the stock /etc/issue greeting.
      if [ "''${1:-}" = "--welcome" ]; then
        printf '\e[H\e[2J%sWelcome to the DNF installer (NixOS %s)%s\n' \
          "$cyan" "${config.system.nixos.label}" "$reset"
      fi

      # Ctrl-C skips the wait: a clean exit lets the login shell finish /etc/profile.
      trap 'echo; exit 0' INT

      # Autologin reaches the shell before the DHCP lease: poll for a route.
      route=""
      for i in $(seq 60); do
        route="$(ip -4 -o route get 1.1.1.1 2>/dev/null || true)"
        if [ -n "$route" ]; then
          break
        fi
        if [ "$i" -eq 1 ]; then
          printf 'Waiting for network (Ctrl-C to skip)...'
        fi
        sleep 1
      done

      # Erase the waiting message, if any: IP + MAC follow the welcome directly.
      printf '\r\e[K'

      if [ -z "$route" ]; then
        printf '\nNo route to the Internet: plug a cable in, or nmtui for Wi-Fi.\n'
        cards
        disks
        exit 0
      fi

      dev="$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' <<< "$route")"
      addr="$(awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }' <<< "$route")"
      mac="$(cat "/sys/class/net/$dev/address")"

      # `- IP:` and `- MAC:` stay first and unchanged: the documentation quotes them.
      printf '\n- IP: %s%s%s\n- MAC: %s%s%s\n' \
        "$magenta" "$addr" "$reset" "$magenta" "$mac" "$reset"
      cards

      # No trailing blank line: the stock NixOS PS1 opens with its own newline.
      disks${keylessHint}${assistantHint}
    '';
  };

  # `darkone new` runs `just install-here` in the project it writes: the
  # tools of its recipes (generation, keys, sops, disko).
  assistantPackages = [
    installer.darkone
    pkgs.age
    pkgs.disko
    pkgs.git
    pkgs.jq
    pkgs.just
    pkgs.mkpasswd
    pkgs.nixfmt
    pkgs.openssl
    pkgs.sops
    pkgs.ssh-to-age
    pkgs.yq-go
    pair
  ];
  assistantHint = lib.optionalString (installer != null) (
    "\n" + "printf '\\nFirst host of a new network: darkone new\\n'"
  );

  # tty1 of the generic image: a menu once a route exists, the binary cache
  # needs it. Until then a cable is picked up by itself, Enter opens nmtui
  # for Wi-Fi. Ctrl-C, or any other console, gives a shell.
  assistant = pkgs.writeShellApplication {
    name = "dnf-assistant";
    runtimeInputs = [
      installer.darkone
      pair
      pkgs.iproute2
      pkgs.util-linux
      config.networking.networkmanager.package
    ];
    text = ''
      online() { ip -4 route get 1.1.1.1 >/dev/null 2>&1; }
      if ! online; then
        printf '\nWaiting for the network: plug a cable in, or press Enter for Wi-Fi.\n'
        until online; do
          if read -r -t 5; then
            nmtui connect || true
          fi
        done
      fi

      # Every path ends in the login shell: tty1 is never left dead.
      while true; do
        printf '\nWhat do you want to do?\n'
        printf '  1) New network: this machine becomes its admin host\n'
        printf '  2) Add this machine to an existing network\n'
        printf '  3) Shell\n'
        printf 'Choice [1-3]: '

        # No default, no timeout: an invalid answer asks again. EOF: shell.
        read -r choice || exit 0
        case "$choice" in
          1)
            darkone new || printf '\ndarkone new stopped. To try again: darkone new\n'
            exit 0
            ;;
          2)
            dnf-pair || printf '\nPairing stopped. To try again: dnf-pair\n'
            exit 0
            ;;
          3)
            exit 0
            ;;
          *)
            printf 'Unknown choice: %s\n' "$choice"
            ;;
        esac
      done
    '';
  };

  # Once per boot (`mkdir` marker): `sudo -i` on tty1 is a login shell too.
  launchAssistant = lib.optionalString (installer != null) (
    "/dev/tty1)\n"
    + "    ${lib.getExe netinfo} --welcome\n"
    + "    ${pkgs.coreutils}/bin/mkdir /tmp/dnf-assistant 2>/dev/null && ${lib.getExe assistant}\n"
    + "    ;;\n  "
  );
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  config = {
    nixpkgs.hostPlatform = stdenv.hostPlatform.system;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.systemd-boot.editor = false;

    # Generic image: a serial console too, autologged in like the others. A
    # headless machine installs through it, and the VM test drives `darkone`
    # there (`tests/installer`). The last `console=` stays the main one.
    boot.kernelParams = lib.mkIf (installer != null) [
      "console=ttyS0,115200n8"
      "console=tty0"
    ];

    # Align with the 26.11 default. The installer image DOES enable ZFS support
    # (so one can install onto a pool), which is precisely why the upstream
    # warning would fire here: a forced import bypasses the guard against
    # adopting a pool owned by another host.
    boot.zfs.forceImportRoot = false;
    hardware.enableAllFirmware = true;

    # Consumer admin pubkey. This is what makes the ISO passwordless-installable:
    # `just full-install <host> nixos <ip>` runs nixos-anywhere as `nixos@<ip>`
    # with the matching private key, and sudo is passwordless (below).
    #
    # sshd authenticates directly from /etc/ssh/authorized_keys.d/nixos (this
    # option writes it), so no ~nixos/.ssh copy is needed for the install to
    # work. The framework standalone ISO has no key (`workDir == null`);
    # consumers get theirs injected via `mkConfigurations` — but only when the
    # ISO is built from the CONSUMER flake (`just build-iso` does this).
    users.users.nixos.openssh.authorizedKeys.keyFiles = lib.mkIf (workDir != null) (
      lib.mkForce [ (workDir + "/usr/secrets/nix.pub") ]
    );

    # Mirror the key into ~nixos/.ssh so a plain `ssh nixos@…` and any tool that
    # reads a classic authorized_keys work on first boot.
    #
    # `deps` is the fix for the old root-owned .ssh: without ordering this raced
    # the built-in `users` script and created .ssh as root before the user's
    # home existed. `etc` guarantees /etc/ssh/authorized_keys.d/nixos is in
    # place; the `[ -e ]` guard skips the keyless standalone ISO. `install`
    # dereferences the /etc symlink, so we get a real 0600 nixos-owned file.
    system.activationScripts.nixosAuthorizedKeys = {
      deps = [
        "users"
        "etc"
      ];
      text = ''
        if [ -e /etc/ssh/authorized_keys.d/nixos ]; then
          install -d -m 700 -o nixos -g users /home/nixos/.ssh
          install -m 600 -o nixos -g users /etc/ssh/authorized_keys.d/nixos /home/nixos/.ssh/authorized_keys
        fi
      '';
    };
    security.sudo.wheelNeedsPassword = false;
    environment.systemPackages = [
      pkgs.vim
      netinfo
    ]
    ++ lib.optionals (installer != null) assistantPackages;

    # Marker of the generic image: the only place `install-here` and
    # `darkone new` erase a disk.
    environment.etc.dnf-installer = lib.mkIf (installer != null) {
      text = "DNF installer image: darkone new erases the disk it installs on.\n";
    };
    environment.variables.DNF_SOURCE = lib.mkIf (installer != null) "${installer.source}";

    # `just try`: defaults of `darkone new`, kept by a manual relaunch. The
    # project pinned on this image's framework (`path:`), not the release.
    environment.variables.DNF_URL = lib.mkIf ((installer.dnfUrl or null) != null) installer.dnfUrl;
    environment.variables.DNF_CACHE = lib.mkIf ((installer.cache or null) != null) installer.cache;
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };

    # Network: NetworkManager of `installation-device.nix`, alone (its own
    # `useDHCP = false`): a dhcpcd beside it would hold the same NIC.
    networking.hostName = "dnf-install";
    services.openssh.enable = true;

    # Pairing code, generic image: no `wantedBy`, `dnf-pair` starts it. The
    # state outlives the run: `Paired` stays on screen. `preStart` drops the
    # last run's, which `dnf-pair` would read before the new code.
    systemd.services.dnf-pair = lib.mkIf (installer != null) {
      description = "DNF pairing code: one-time nixos password for the admin host";
      after = [ "sshd-keygen.service" ];
      wants = [ "sshd-keygen.service" ];
      preStart = "${pkgs.coreutils}/bin/rm -f ${pairState}";
      script = pairService;
      serviceConfig = {
        RuntimeDirectory = "dnf-pair";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = true;
      };
    };

    # 10^6 codes against a 10 min window: 10 pre-auth slots, 10 s per wrong
    # password (stock: up to 100, 2 s), so ~1 try/s, ~600 per code. Generic
    # image only: a consumer image has no password to guess.
    services.openssh.settings.MaxStartups = lib.mkIf (installer != null) "10";
    security.pam.services.sshd.failDelay = lib.mkIf (installer != null) {
      enable = true;
      delay = 10000000;
    };

    # Stock NixOS greeting + installer help, a getty `mkDefault`: superseded by
    # the DNF welcome below.
    environment.etc.issue.text = "";

    # Installer autologins on the consoles: agetty prints /etc/issue before
    # DHCP, then the shell scrolls it away. Print from the login shell instead;
    # local ttys only, an SSH caller already knows the address.
    environment.loginShellInit = ''
      case "$(${pkgs.coreutils}/bin/tty)" in
        ${launchAssistant}/dev/tty[0-9]*) ${lib.getExe netinfo} --welcome ;;
      esac
    '';

    system.stateVersion = "26.11";
  };
}
