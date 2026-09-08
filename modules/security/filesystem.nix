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
# `noexec` on /tmp blocks execution *and* `dlopen`: it breaks installers and
# compilers running what they unpack (pip, cargo, gcc) and any runtime
# extracting native libraries there (Bun, Electron, agent tooling). Nix builds
# are covered — the daemon's TMPDIR moves to /var/tmp. Opt out per host with
# `darkone.security.filesystem.tmpNoexec = false`.
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

    darkone.security.filesystem.tmpfs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether R28 owns `/tmp` as a hardened tmpfs sized on
        `boot.tmp.tmpfsSize`. Set to `false` to leave `/tmp` on the filesystem
        it already lives on — a host keeping several GB of persistent scratch
        there loses both the data and the RAM otherwise.
      '';
    };

    darkone.security.filesystem.tmpNoexec = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the R28 `/tmp` carries `noexec`. `noexec` blocks direct
        execution *and* `dlopen`, so it breaks any runtime unpacking native
        libraries there (Bun, Electron, agent tooling) and anything compiling
        then running in `TMPDIR`. Only meaningful when `tmpfs` is `true`.
      '';
    };

    darkone.security.filesystem.extraMountHardening = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "/var/log"
        "/srv"
        "/home"
      ];
      description = ''
        Mount points to harden with `nosuid,nodev,noexec` (R28). Each listed
        path MUST be a separate partition declared elsewhere (hardware-
        configuration / disko); the options are merged into its existing
        `fileSystems` entry. An explicit list (rather than a global flag)
        avoids guessing the layout and never creates phantom mounts. Do not
        list `/home` if users run scripts there — `noexec` would break them.
      '';
    };
  };

  config = lib.mkMerge [
    { darkone.security.filesystem.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R28 — Typical partitioning and mount options (intermediary, base)
        # sideEffects: noexec /tmp breaks compilers; hidepid=2 hides non-root processes
        (lib.mkIf (isActive "R28" "intermediary" "base" [ ]) {

          # R28 owns /tmp. `boot.tmp.useTmpfs` writes a static `tmp.mount` that
          # carries no `noexec` and outranks the fstab entry generated here:
          # two contradictory definitions, the weaker one winning silently.
          boot.tmp.useTmpfs = lib.mkIf cfg.tmpfs (lib.mkForce false);
          boot.tmp.tmpfsSize = lib.mkDefault "25%";

          # `noexec` breaks any build unpacking and running a configure script
          # in TMPDIR. Nix 2.34 has no `build-dir` setting, so move the daemon.
          systemd.services.nix-daemon.environment.TMPDIR = lib.mkDefault "/var/tmp";

          # Mount options for /tmp and any operator-declared extra partitions
          # (R28). A single `fileSystems` definition: mixing dotted-path and
          # whole-attr forms in one attrset is illegal, so everything goes
          # through `mkMerge`. Extra paths only add `options` to filesystems
          # the operator already declared — never a phantom mount.
          fileSystems = lib.mkMerge (
            lib.optional cfg.tmpfs {
              "/tmp" = {
                device = "tmpfs";
                fsType = "tmpfs";
                options = [
                  "nosuid"
                  "nodev"
                  "mode=1777"
                  "size=${toString config.boot.tmp.tmpfsSize}"
                ]
                ++ lib.optional cfg.tmpNoexec "noexec";
              };
            }
            ++ map (mountPoint: {
              ${mountPoint}.options = [
                "nosuid"
                "nodev"
                "noexec"
              ];
            }) cfg.extraMountHardening
          );

          # /proc with hidepid=2 (hides non-root processes)
          # Without members the group hides every process from `ps`, `htop`
          # and the GNOME monitor — including from the operators repairing the
          # host. `wheel` is the fleet's administrator set, `nix` included.
          # (plain definition: nixpkgs also defines `members`, and list options
          # concatenate — a `mkDefault` here would simply be overridden.)
          users.groups.proc = {
            gid = config.ids.gids.proc;
            members = lib.attrNames (lib.filterAttrs (_: u: lib.elem "wheel" u.extraGroups) config.users.users);
          };

          # `gid=` must be numeric. procfs parses the option in the kernel, with
          # no NSS lookup, and `specialfs` remounts /proc long before the group
          # exists anyway: `gid=proc` made the remount fail, leaving /proc
          # unmounted for the rest of activation. The `modprobe` snippet then
          # could not write /proc/sys/kernel/modprobe, module autoload stayed on
          # the non-existent /sbin/modprobe, and nftables died at boot.
          boot.specialFileSystems."/proc" = {
            options = [
              "hidepid=2"
              "gid=${toString config.ids.gids.proc}"
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

            # Audit journals. `/var/log/sudo-io` is R39's (sudo.nix), which
            # already creates it 0750 root adm along with its rotation.
            "d /etc/audit          0750 root adm   -"
            "d /var/log/audit      0750 root adm   -"

            # System logs (if directory exists)
            "Z /var/log/nginx      0640 nginx adm  -"
            "Z /var/log/sshd       0640 root  adm  -"
          ];
        })

        # R51 — Change secrets from installation (reinforced, base)
        # sideEffects: cannot deploy without access to the sops-nix vault
        (lib.mkIf (isActive "R51" "reinforced" "base" [ ]) {

          # Assertion: forbid cleartext passwords landing in the Nix store.
          # Only `hashedPassword`/`hashedPasswordFile` are acceptable; the
          # cleartext `password`/`initialPassword` attrs must transit through
          # sops-nix instead (core.nix integration).
          assertions =
            let
              cleartextUsers = lib.attrNames (
                lib.filterAttrs (_: u: u.password != null || u.initialPassword != null) config.users.users
              );
            in
            [
              {
                assertion = cleartextUsers == [ ];
                message =
                  "R51: cleartext password(s) in the Nix store for: "
                  + lib.concatStringsSep ", " cleartextUsers
                  + ". Use hashedPasswordFile via sops-nix instead.";
              }
            ];
        })

        # R52 — Sockets and named pipes (intermediary, base)
        # sideEffects: legacy services (X11 abstract socket) must migrate
        (lib.mkIf (isActive "R52" "intermediary" "base" [ ]) {

          # 0750 runtime dirs on opted-in units (shared list with R55/R63).
          # Full coverage of every unit would need a global systemd hook;
          # the hardenedUnits allowlist keeps it explicit and auditable.
          systemd.services = lib.genAttrs config.darkone.security.services.hardenedUnits (_: {
            serviceConfig.RuntimeDirectoryMode = lib.mkDefault "0750";
          });
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
                ${pkgs.findutils}/bin/find / -xdev \( -nouser -o -nogroup \) \
                  -not -path '/nix/store/*' \
                  -not -path '/proc/*' \
                  -ls 2>/dev/null \
                  | ${pkgs.util-linux}/bin/logger -t anssi-r53 -p security.warning
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

          # Per-service private /tmp on opted-in units. PrivateTmp is the
          # systemd-native equivalent of pam_namespace and far simpler to
          # operate; pam_namespace (/etc/security/namespace.conf) stays a
          # documented alternative for login-session isolation.
          systemd.services = lib.genAttrs config.darkone.security.services.hardenedUnits (_: {
            serviceConfig.PrivateTmp = lib.mkDefault true;
          });
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
                ${pkgs.findutils}/bin/find / -xdev -type f -perm /6000 -ls 2>/dev/null | while read -r line; do
                  bin=$(echo "$line" | ${pkgs.gawk}/bin/awk '{print $NF}')
                  base=$(${pkgs.coreutils}/bin/basename "$bin")
                  found=0
                  for a in $ALLOWED; do [ "$base" = "$a" ] && found=1 && break; done
                  [ $found -eq 0 ] && echo "WARNING: unexpected setuid: $bin" | ${pkgs.util-linux}/bin/logger -t anssi-r56 -p security.warning
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
