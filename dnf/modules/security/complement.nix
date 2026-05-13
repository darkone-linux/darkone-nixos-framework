# Cross-cutting complementary measures — Annex A (C1–C12). (wip)
#
# These measures have no ANSSI number but are essential to the guide's spirit.
# Covers linux-hardened patches (C1), Lockdown LSM (C2), USBGuard (C3),
# nftables deny-by-default (C4), hardened SSH (C5), LUKS2 (C6), NTP/NTS (C7),
# secure DNS (C8), disabled core dumps (C9), PAM anti brute-force (C10),
# legal banners (C11), and cron/at restriction (C12).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::note[Lockdown LSM level (C2)]
# - `none`: no Lockdown.
# - `integrity`: forbids kernel modifications via userspace.
# - `confidentiality`: same + forbids reading kernel secrets.
# :::
#
# :::caution[C2 — Lockdown LSM]
# `lockdown=confidentiality` forbids kexec, /dev/mem writes, MSR, hibernation.
# Breaks `dmidecode` on some zones, `flashrom`, `i2c-tools`.
# :::
#
# :::caution[C4 — Egress filtering]
# The egress deny-by-default policy breaks tools that reach CDNs (curl,
# kernel downloads). Required: a controlled outbound HTTP(S) proxy.
# :::
#
# :::caution[C5 — Hardened SSH]
# SSH tunnels, agent forwarding, and X11 disabled. Adapt admin workflows
# to ProxyJump (`ssh -J`). This module overrides `core.nix` for SSH.
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.complement;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.complement.enable = lib.mkEnableOption "Enable complementary ANSSI measures (C1–C12).";

    darkone.security.complement.lockdownLevel = lib.mkOption {
      type = lib.types.enum [
        "none"
        "integrity"
        "confidentiality"
      ];
      default = "integrity";
      description = "Lockdown LSM level (C2)";
    };

    darkone.security.complement.lsmStack = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "lockdown"
        "yama"
        "bpf"
        "landlock"
      ];
      description = "LSM stack order (C2, R11, R20). Modifies boot.kernelParams lsm=...";
    };

    darkone.security.complement.ntpServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "time.cloudflare.com" ];
      description = "NTP/NTS servers (C7).";
    };

    darkone.security.complement.useNts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable NTS (Network Time Security) for NTP authentication (C7).";
    };

    darkone.security.complement.sshBanner = lib.mkOption {
      type = lib.types.str;
      default = ''
        *** Access restricted to authorized personnel ***
        All connections are logged and may be subject to prosecution.
      '';
      description = "SSH banner displayed before authentication (C11).";
    };

    darkone.security.complement.cronAllowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "root" ];
      description = "Users allowed to schedule cron jobs (C12).";
    };

    darkone.security.complement.egressAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "IP/CIDR allowed outbound for strict nftables egress filtering (C4).";
    };
  };

  config = lib.mkMerge [
    { darkone.security.complement.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # C1 — linux-hardened patches (high, tag: kernel-recompile)
        # Handled by kernel-build.nix via mainSecurityCfg.useHardenedKernel = true
        # linux-hardened specific sysctls
        (lib.mkIf (isActive "C1" "high" "base" [ "kernel-recompile" ] && mainSecurityCfg.useHardenedKernel)
          {
            boot.kernelParams = [ "extra_latent_entropy" ];
            boot.kernel.sysctl = {
              "kernel.tiocsti_restrict" = 1; # Restricts artificial character injection in the terminal.
              "kernel.device_sidechannel_restrict" = 1; # Restricts unprivileged access to device / perf info.
              "kernel.perf_event_paranoid" = 3; # Extended semantics in linux-hardened — controls access to perf.
            }
            // lib.optionalAttrs (!lib.elem "needs-usb-hotplug" mainSecurityCfg.excludes) {

              # Prevents adding new USB devices after boot or after the parameter is enabled
              "kernel.deny_new_usb" = lib.mkIf (mainSecurityCfg.category == "client") 1;
            };
          }
        )

        # C2 — Lockdown LSM - Linux Security Module (high)
        # sideEffects: forbids kexec, /dev/mem, MSR, hibernation, some kernel reads
        (lib.mkIf (isActive "C2" "high" "base" [ ]) {
          boot.kernelParams = [
            "lsm=${lib.concatStringsSep "," cfg.lsmStack}"
          ]
          ++ lib.optional (cfg.lockdownLevel != "none") "lockdown=${cfg.lockdownLevel}";
        })

        # C3 — USBGuard (reinforced, client + server recommended, tag: needs-usb-hotplug)
        # sideEffects: any new USB device blocked without prior whitelist
        (lib.mkIf (isActive "C3" "reinforced" "client" [ "needs-usb-hotplug" ]) {
          services.usbguard = {
            enable = true;

            # Implicit policy: block any undeclared device
            implicitPolicyTarget = "block";

            # TODO: generate ruleset from devices validated at installation time
            # rules = '' allow id ... '' ;
          };
        })

        # C4 — nftables with deny-by-default policy (minimal → reinforced)
        # sideEffects: egress filtering breaks curl/downloads without an outbound proxy
        (lib.mkIf (isActive "C4" "minimal" "base" [ ]) {
          networking.nftables.enable = true;
          networking.firewall.enable = true;

          # Deny-by-default policy: no port open unless explicitly declared
          networking.firewall.allowedTCPPorts = lib.mkDefault [ 22 ];

          # Egress filtering (reinforced level only)
          # TODO: output deny chain + allowlist via cfg.egressAllowlist
        })

        # C5 — OpenSSH hardening (intermediary, base)
        # sideEffects: tunnels, agent forwarding, and X11 disabled
        # NOTE: overrides core.nix SSH config (this module is mandatory per Q3)
        (lib.mkIf (isActive "C5" "intermediary" "base" [ ]) {
          services.openssh = {

            # Do not disable SSH here — core.nix enables it, we only harden
            settings = {
              PermitRootLogin = lib.mkForce "no";
              PasswordAuthentication = lib.mkForce false;
              KbdInteractiveAuthentication = lib.mkForce false;
              PermitEmptyPasswords = lib.mkForce "no";
              X11Forwarding = lib.mkForce false;
              AllowAgentForwarding = lib.mkForce "no";
              AllowTcpForwarding = lib.mkForce "no";
              GatewayPorts = lib.mkForce "no";
              LogLevel = lib.mkDefault "VERBOSE";
              MaxAuthTries = lib.mkDefault 3;
              LoginGraceTime = lib.mkDefault 30;
              ClientAliveInterval = lib.mkDefault 300;
              ClientAliveCountMax = lib.mkDefault 2;

              # ANSSI-NT-007 compliant algorithms
              KexAlgorithms = [
                "sntrup761x25519-sha512@openssh.com"
                "curve25519-sha256"
                "curve25519-sha256@libssh.org"
              ];
              Ciphers = [
                "chacha20-poly1305@openssh.com"
                "aes256-gcm@openssh.com"
                "aes128-gcm@openssh.com"
              ];
              Macs = [
                "hmac-sha2-512-etm@openssh.com"
                "hmac-sha2-256-etm@openssh.com"
              ];
              HostKeyAlgorithms = [
                "ssh-ed25519"
                "rsa-sha2-512"
              ];
            };
            banner = "/etc/issue.net";
          };
        })

        # C6 — LUKS2 disk encryption (intermediary laptop, reinforced server)
        # sideEffects: disk performance -5-15%, cannot extract without the key
        (lib.mkIf (isActive "C6" "intermediary" "base" [ ]) {

          # LUKS configuration is declared in disko.nix (out of scope for this module)
          # This module only ensures swap is encrypted if present
          swapDevices = lib.mkIf (config.swapDevices != [ ]) (
            map (
              swap:
              swap
              // lib.optionalAttrs (!(swap.randomEncryption.enable or false)) { randomEncryption.enable = true; }
            ) config.swapDevices
          );

          # TODO: assertion verifying / or /home is on LUKS (via blkid in checkScript)
        })

        # C7 — NTS time synchronization (intermediary, base)
        # sideEffects: NTS requires compatible servers, UDP/123 + TCP/4460 traffic
        (lib.mkIf (isActive "C7" "intermediary" "base" [ ]) {
          services.chrony = {
            enable = true;
            servers = cfg.ntpServers;
            extraConfig = lib.optionalString cfg.useNts ''
              ${lib.concatMapStringsSep "\n" (s: "server ${s} nts") cfg.ntpServers}
            '';
          };
        })

        # C8 — Secure DNS resolver DNSSEC + DoT (intermediary, base)
        # sideEffects: non-DNSSEC internal zones need Domains=~example.internal
        (lib.mkIf (isActive "C8" "intermediary" "base" [ ]) {
          services.resolved = {
            dnssec = "true";
            dnsovertls = "true";
            fallbackDns = [ ]; # No cleartext DNS fallback
          };
        })

        # C9 — Disable core dumps (reinforced, base)
        # sideEffects: post-mortem analysis impossible without dedicated environment
        (lib.mkIf (isActive "C9" "reinforced" "base" [ ]) {
          systemd.coredump.enable = false;
          security.pam.loginLimits = [
            {
              domain = "*";
              type = "hard";
              item = "core";
              value = "0";
            }
          ];
          boot.kernel.sysctl."kernel.core_pattern" = "|/bin/false";
        })

        # C10 — Anti brute-force and session limits (intermediary, base)
        # sideEffects: attacker can trigger intentional lock-out (account DoS)
        (lib.mkIf (isActive "C10" "intermediary" "base" [ ]) {
          security.pam.loginLimits = [
            {
              domain = "*";
              type = "-";
              item = "nproc";
              value = "2048";
            }
            {
              domain = "*";
              type = "-";
              item = "nofile";
              value = "4096";
            }
            {
              domain = "*";
              type = "-";
              item = "maxlogins";
              value = "10";
            }
          ];
        })

        # C11 — Banners and legal messages (minimal, base)
        # sideEffects: none
        (lib.mkIf (isActive "C11" "minimal" "base" [ ]) {
          environment.etc."issue".text = cfg.sshBanner;
          environment.etc."issue.net".text = cfg.sshBanner;
        })

        # C12 — cron/at restriction (minimal, base)
        # sideEffects: unlisted users can no longer schedule jobs
        (lib.mkIf (isActive "C12" "minimal" "base" [ ]) {

          # cron allowlist
          environment.etc."cron.allow".text = lib.concatStringsSep "\n" cfg.cronAllowedUsers + "\n";

          # Block everyone else
          environment.etc."cron.deny".text = "ALL\n";

          # TODO: at.allow via services.atd if enabled
        })
      ]
    ))
  ];
}
