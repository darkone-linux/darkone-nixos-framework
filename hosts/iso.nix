# DNF ISO image for fast workstation installs.
#
# -> Build the image:
# nix build .#nixosConfigurations.iso-x86_64-linux.config.system.build.isoImage
#
# -> Install with the image:
# dnf-netinfo # IP + MAC to use, also printed on the console at boot
# just full-install my-host nixos 10.1.3.211 # Install "my-host"
#
# -> First host of a new network (generic image only, launched on tty1):
# darkone new # this machine becomes the admin host (--answers: scripted)

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

  # IP + MAC of the interface holding the route to the Internet, i.e. the one
  # `just full-install` reaches. `ip route get` resolves only, sends no packet.
  netinfo = pkgs.writeShellApplication {
    name = "dnf-netinfo";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.iproute2
    ];
    text = ''
      cyan=$'\e[1;36m'
      magenta=$'\e[1;35m'
      reset=$'\e[0m'

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
        printf '\nNo route to the Internet, run dnf-netinfo once connected.\n'
        exit 0
      fi

      dev="$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' <<< "$route")"
      addr="$(awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }' <<< "$route")"
      mac="$(cat "/sys/class/net/$dev/address")"

      # No trailing blank line: the stock NixOS PS1 opens with its own newline.
      printf '\n- IP: %s%s%s\n- MAC: %s%s%s\n' \
        "$magenta" "$addr" "$reset" "$magenta" "$mac" "$reset"${keylessHint}${assistantHint}
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

  # tty1 of the generic image runs the assistant once a route exists: it needs
  # the binary cache. Ctrl-C in it, or any other console, gives a shell. Once
  # per boot (`mkdir` marker): `sudo -i` on tty1 is a login shell too.
  launchAssistant = lib.optionalString (installer != null) (
    "/dev/tty1)\n"
    + "    ${lib.getExe netinfo} --welcome\n"
    + "    ${pkgs.coreutils}/bin/mkdir /tmp/dnf-assistant 2>/dev/null"
    + " && ${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 >/dev/null 2>&1"
    + " && ${installer.darkone}/bin/darkone new\n"
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
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
    networking.useDHCP = lib.mkForce true;
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
