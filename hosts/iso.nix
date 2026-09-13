# DNF ISO image for fast workstation installs.
#
# -> Build the image:
# nix build .#nixosConfigurations.iso-x86_64-linux.config.system.build.isoImage
#
# -> Install with the image:
# dnf-netinfo # IP + MAC to use, also printed on the console at boot
# just full-install my-host nixos 10.1.3.211 # Install "my-host"

{
  config,
  modulesPath,
  stdenv,
  lib,
  pkgs,
  workDir ? null,
  ...
}:
let

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
        "$magenta" "$addr" "$reset" "$magenta" "$mac" "$reset"
    '';
  };
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  config = {
    nixpkgs.hostPlatform = stdenv.hostPlatform.system;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.systemd-boot.editor = false;

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
    ];
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
        /dev/tty[0-9]*) ${lib.getExe netinfo} --welcome ;;
      esac
    '';

    system.stateVersion = "26.11";
  };
}
