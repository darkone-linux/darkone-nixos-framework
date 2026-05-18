# Partitioning, file tree, and file permissions (R28–R29, R50–R57). (wip)
#
# Covers secure mount options (R28), restriction of /boot (R29),
# permissions of sensitive files (R50), passwords kept out of the store (R51),
# sockets (R52), orphan files (R53), sticky bit (R54),
# per-user temporary directories (R55), and setuid (R56, R57).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R28 — noexec /tmp]
# `noexec` on /tmp breaks many installers and compilers (pip, cargo, gcc).
# Workaround: `export TMPDIR=$XDG_RUNTIME_DIR` in shell profiles.
# :::
#
# :::caution[R29 — /boot noauto]
# `noauto` on /boot requires a manual remount on every NixOS update.
# A `nixos-rebuild` wrapper must ensure automatic mount/unmount.
# :::

{
  lib,
  dnfLib,
  config,
  pkgs,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.filesystem;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.filesystem.enable = lib.mkEnableOption "Enable ANSSI filesystem hardening (R28–R29, R50–R57).";

    darkone.security.filesystem.allowedSetuid = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "sudo"
        "mount"
        "umount"
        "passwd"
        "chsh"
        "chfn"
        "unix_chkpwd"
        "newuidmap"
        "newgidmap"
      ];
      description = "Allowlist of tolerated setuid/setgid binaries (R56, R57).";
    };
  };

  config = lib.mkMerge [
    { darkone.security.filesystem.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R28 — Typical partitioning and mount options (intermediary, base)
        # sideEffects: noexec /tmp breaks compilers; hidepid=2 hides non-root processes
        (lib.mkIf (isActive "R28" "intermediary" "base" [ ]) {

          # /tmp as tmpfs with restrictive options
          boot.tmp.useTmpfs = lib.mkDefault true;
          boot.tmp.tmpfsSize = lib.mkDefault "25%";

          # Mount options for /tmp
          fileSystems."/tmp" = lib.mkIf config.boot.tmp.useTmpfs {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [
              "nosuid"
              "nodev"
              "noexec"
              "size=25%"
              "mode=1777"
            ];
          };

          # /proc with hidepid=2 (hides non-root processes)
          # proc group required for legitimate tools (ps, htop as root)
          users.groups.proc = lib.mkDefault { };
          boot.specialFileSystems."/proc" = {
            options = [
              "hidepid=2"
              "gid=proc"
            ];
          };

          # /dev/shm without exec
          boot.specialFileSystems."/dev/shm" = {
            options = [
              "nosuid"
              "nodev"
              "noexec"
            ];
          };

          # Tmpfiles: /var/tmp permissions
          systemd.tmpfiles.rules = [
            "d /var/tmp 1777 root root -" # sticky bit
          ];

          # TODO: nosuid,nodev,noexec options on /var/log, /home, /srv, /opt
          # via fileSystems if these mount points are separate partitions.
          # On NixOS, these options only apply if the partition exists.
        })

        # R29 — Restrict /boot (reinforced, base)
        # sideEffects: noauto + nixos-rebuild requires a remount wrapper
        (lib.mkIf (isActive "R29" "reinforced" "base" [ ]) {

          # 700 permissions on /boot
          system.activationScripts.bootPerm = ''
            if [ -d /boot ]; then
              chmod 0700 /boot
            fi
          '';

          # DECISION: noauto options are not set by default as they break
          # `nixos-rebuild switch` without a wrapper. Enable manually via a
          # wrapper or via a darkone.security.filesystem.bootNoauto option.
          # fileSystems."/boot".options = [ "nosuid" "nodev" "noexec" "noauto" ];
        })

        # R50 — Restrict sensitive files (intermediary, base)
        # sideEffects: none major on NixOS (permissions already correct by default)
        (lib.mkIf (isActive "R50" "intermediary" "base" [ ]) {
          systemd.tmpfiles.rules = [

            # Audit and sudo journals
            "d /etc/audit          0750 root adm   -"
            "d /var/log/audit      0750 root adm   -"
            "d /var/log/sudo-io    0750 root adm   -"

            # System logs (if directory exists)
            "Z /var/log/nginx      0640 nginx adm  -"
            "Z /var/log/sshd       0640 root  adm  -"
          ];
        })

        # R51 — Change secrets from installation (reinforced, base)
        # sideEffects: cannot deploy without access to the sops-nix vault
        (lib.mkIf (isActive "R51" "reinforced" "base" [ ]) {

          # Assertion: forbid plaintext hashedPassword in the Nix store
          # Passwords must transit through sops-nix (core.nix integration)
          assertions = [
            {
              assertion = lib.all (
                _user: true

                # TODO: verify hashedPassword is not a plaintext hash
                # The real check requires inspecting users.users.*.hashedPassword
                # and comparing to a blocklist (p4ssw0rd, empty hash, default Debian hashes)
              ) (lib.attrValues config.users.users);
              message = "R51: Passwords must be managed via sops-nix, not in plaintext.";
            }
          ];
        })

        # R52 — Sockets and named pipes (intermediary, base)
        # sideEffects: legacy services (X11 abstract socket) must migrate
        (lib.mkIf (isActive "R52" "intermediary" "base" [ ]) {

          # Enforce RuntimeDirectoryMode=0750 by default for systemd services
          systemd.services = lib.mkDefault { };

          # TODO: apply `serviceConfig.RuntimeDirectoryMode = "0750"` to all services
          # via a systemd overlay module — requires an explicit list or a global hook
        })

        # R53 — No orphan files (minimal, base)
        # sideEffects: /nix/store allowlist recommended (transient UIDs)
        (lib.mkIf (isActive "R53" "minimal" "base" [ ]) {

          # Weekly detection timer (report only, no auto-correction)
          systemd.timers.anssi-orphan-scan = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "weekly";
              Persistent = true;
            };
          };
          systemd.services.anssi-orphan-scan = {
            description = "ANSSI R53: scan for files without owner";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = pkgs.writeShellScript "anssi-orphan-scan" ''
                find / -xdev \( -nouser -o -nogroup \) \
                  -not -path '/nix/store/*' \
                  -not -path '/proc/*' \
                  -ls 2>/dev/null \
                  | logger -t anssi-r53 -p security.warning
              '';
            };
          };
        })

        # R54 — Sticky bit on world-writable directories (minimal, base)
        (lib.mkIf (isActive "R54" "minimal" "base" [ ]) {
          systemd.tmpfiles.rules = [
            "d /tmp     1777 root root -"
            "d /var/tmp 1777 root root -"
          ];
        })

        # R55 — Per-user temporary directories (intermediary, base)
        # sideEffects: pam_namespace requires /etc/security/namespace.conf
        (lib.mkIf (isActive "R55" "intermediary" "base" [ ]) {

          # systemd-native alternative: PrivateTmp=true at service level (cf. R63)
          # pam_namespace is more complete but more complex to configure
          # TODO: configure pam_namespace or document PrivateTmp as alternative
        })

        # R56 — Avoid arbitrary setuid/setgid (minimal, base)
        # sideEffects: removing binaries may break user tools
        (lib.mkIf (isActive "R56" "minimal" "base" [ ]) {

          # Detection timer for setuid binaries outside the allowlist
          systemd.timers.anssi-setuid-scan = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "weekly";
              Persistent = true;
            };
          };
          systemd.services.anssi-setuid-scan = {
            description = "ANSSI R56: scan setuid binaries outside the allowlist";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = pkgs.writeShellScript "anssi-setuid-scan" ''
                ALLOWED="${lib.concatStringsSep " " cfg.allowedSetuid}"
                find / -xdev -type f -perm /6000 -ls 2>/dev/null | while read -r line; do
                  bin=$(echo "$line" | awk '{print $NF}')
                  base=$(basename "$bin")
                  found=0
                  for a in $ALLOWED; do [ "$base" = "$a" ] && found=1 && break; done
                  [ $found -eq 0 ] && echo "WARNING: unexpected setuid: $bin" | logger -t anssi-r56 -p security.warning
                done
              '';
            };
          };
        })

        # R57 — Minimal setuid root (reinforced, base)
        # Subset of R56: strict allowlist + capabilities preference
        (lib.mkIf (isActive "R57" "reinforced" "base" [ ]) {

          # ping via capabilities (cap_net_raw) rather than setuid
          security.wrappers.ping = lib.mkDefault {
            source = "${pkgs.iputils}/bin/ping";
            owner = "root";
            group = "root";
            capabilities = "cap_net_raw+ep";
          };

          # TODO: other binaries to migrate from setuid to capabilities (traceroute, etc.)
        })
      ]
    ))
  ];
}
