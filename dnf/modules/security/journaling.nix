# Logging and auditd (R71–R73). (wip)
#
# Covers persistent logging with TLS forwarding (R71),
# per-service dedicated journals (R72), and auditd with ANSSI rules (R73).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R71 — Seal=yes]
# `Seal=yes` requires `journalctl --setup-keys` (out-of-band audit key).
# Without this key, journal integrity cannot be verified.
# :::
#
# :::caution[R73 — immutable auditd]
# The configuration `audit.rules = [ "-e 2" ]` makes auditd immutable: any
# rule change requires a reboot. Test in staging before deployment.
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.journaling;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.journaling.enable = lib.mkEnableOption "Enable ANSSI logging and auditd (R71–R73).";
  };

  config = lib.mkMerge [
    { darkone.security.journaling.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R71 — Persistent logging system (reinforced, base)
        # sideEffects: Seal=yes requires out-of-band setup-keys
        (lib.mkIf (isActive "R71" "reinforced" "base" [ ]) {
          services.journald.extraConfig = ''
            Storage=persistent
            Compress=yes
            Seal=yes
            ForwardToSyslog=yes
            MaxLevelStore=info
            MaxLevelSyslog=info
            RateLimitIntervalSec=30s
            RateLimitBurst=2000
            SystemMaxUse=2G
            SystemKeepFree=1G
          '';

          # TLS forwarder to central collector
          # Prefer omrelp (RELP with application-level ack) over plain TCP
          # TODO: configure services.rsyslogd with TLS destination (option to be added)
          # services.rsyslogd.enable = true;
        })

        # R72 — Per-service dedicated journals (reinforced, base)
        # sideEffects: more files; logrotate rotation required
        (lib.mkIf (isActive "R72" "reinforced" "base" [ ]) {

          # TODO: generate rsyslogd rules per registered DNF service
          # services.rsyslogd.extraConfig = ''
          #   if $programname == 'nginx'  then -/var/log/nginx.log
          #   if $programname == 'sshd'   then -/var/log/sshd.log
          # '';
          # Permissions via tmpfiles (cf. R50)
          systemd.tmpfiles.rules = [
            "f /var/log/nginx.log  0640 root adm -"
            "f /var/log/sshd.log   0640 root adm -"
          ];
        })

        # R73 — auditd (reinforced, base, tag: no-auditd)
        # sideEffects: significant I/O (1-10% CPU on syscall-heavy workloads)
        (lib.mkIf (isActive "R73" "reinforced" "base" [ "no-auditd" ]) {
          security.audit.enable = true;
          security.audit.rules = [

            # Critical syscalls
            "-a exit,always -F arch=b64 -S execve,execveat"
            "-a exit,always -F arch=b64 -S clock_settime -S settimeofday -S adjtimex"
            "-a exit,always -F arch=b64 -S sethostname -S setdomainname"
            "-a exit,always -F arch=b64 -S kexec_load -S kexec_file_load"

            # Sensitive files
            "-w /etc/sudoers      -p wa"
            "-w /etc/sudoers.d/   -p wa"
            "-w /etc/passwd       -p wa"
            "-w /etc/shadow       -p wa"
            "-w /var/log/auth.log -p wa"

            # Make the configuration immutable (reboot required to change rules)
            "-e 2"
          ];
        })

      ]
    ))
  ];
}
