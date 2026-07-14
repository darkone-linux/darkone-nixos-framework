# DNF ISO image for fast workstation installs.
#
# -> Build the image:
# nix build .#nixosConfigurations.iso-x86_64-linux.config.system.build.isoImage
#
# -> Install with the image:
# ping dnf-install # locate the IP address
# just full-install my-host nixos 10.1.3.211 # Install "my-host"

{
  modulesPath,
  stdenv,
  lib,
  pkgs,
  workDir ? null,
  ...
}:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  config = {
    nixpkgs.hostPlatform = stdenv.hostPlatform.system;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.systemd-boot.editor = false;

    # Align with the 26.11 default — silences the upstream warning. No ZFS
    # is used in the ISO; same rationale as in dnf/modules/system/core.nix.
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
    environment.systemPackages = with pkgs; [ vim ];
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
    networking.useDHCP = lib.mkForce true;
    networking.hostName = "dnf-install";
    services.openssh.enable = true;

    # Show the reachable IPs at the login prompt (handy for `just full-install
    # <host> nixos <ip>`). agetty auto-appends /etc/issue.d/*.issue to the
    # greeting; /etc itself is writable on the ISO overlay, so a oneshot drops
    # the file there once the network is up. The prompt renders it on its next
    # refresh (press Enter) if getty came up before DHCP.
    systemd.services.dnf-netinfo = {
      description = "Publish network interfaces + IPs to the login prompt";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.coreutils}/bin/mkdir -p /etc/issue.d
        {
          echo ""
          echo "Network interfaces:"
          ${pkgs.iproute2}/bin/ip -o -4 addr show scope global \
            | ${pkgs.gawk}/bin/awk '{ print "  - " $2 ": " $4 }'
          echo ""
        } > /etc/issue.d/10-dnf-network.issue
      '';
    };

    system.stateVersion = "26.05";
  };
}
