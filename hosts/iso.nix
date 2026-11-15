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
# 2) add this machine to an existing network (cards, disks, passwd...)
# 3) shell

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
  # `nixos` account has an empty password, which sshd refuses: one `passwd`
  # lets `ssh-copy-id` in. Empty for a consumer ISO, whose drvPath stays put.
  keylessHint = lib.optionalString (workDir == null) (
    "\n"
    + ''printf '\nNo admin key in this image. Set a password with passwd, then from\nthe admin host: sudo -i -u nix ssh-copy-id nixos@%s\n' "$addr"''
  );

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
      netinfo
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

            # The route may be gone since the wait: a placeholder, not an exit.
            route="$(ip -4 -o route get 1.1.1.1 2>/dev/null || true)"
            addr='<this-ip>'
            if [[ "$route" == *" src "* ]]; then
              addr="''${route#* src }"
              addr="''${addr%% *}"
            fi

            dnf-netinfo --list

            printf '\nTo add this machine to your network:\n'
            printf '  1. Set a password here: passwd\n'
            printf '  2. From the admin host: sudo -i -u nix ssh-copy-id nixos@%s\n' "$addr"
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
