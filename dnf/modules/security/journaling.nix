# Journalisation et auditd (R71–R73). (wip)
#
# Couvre le système de journalisation persistant avec forwarding TLS (R71),
# les journaux dédiés par service (R72) et auditd avec les règles ANSSI (R73).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R71 — Seal=yes]
# `Seal=yes` requiert `journalctl --setup-keys` (clé d'audit hors-bande).
# Sans cette clé, l'intégrité des journaux ne peut pas être vérifiée.
# :::
#
# :::caution[R73 — auditd immuable]
# La configuration `audit.rules = [ "-e 2" ]` rend auditd immuable : tout
# changement de règle nécessite un reboot. Tester en staging avant déploiement.
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
    darkone.security.journaling.enable = lib.mkEnableOption "Active la journalisation et auditd ANSSI (R71–R73).";
  };

  config = lib.mkMerge [
    { darkone.security.journaling.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R71 — Système de journalisation persistant (reinforced, base)
        # sideEffects: Seal=yes requiert setup-keys hors-bande
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

          # Forwarder TLS vers collecteur central
          # Préférer omrelp (RELP avec ack applicatif) à TCP simple
          # TODO: configurer services.rsyslogd avec destination TLS (option à ajouter)
          # services.rsyslogd.enable = true;
        })

        # R72 — Journaux dédiés par service (reinforced, base)
        # sideEffects: multiplication des fichiers ; rotation logrotate nécessaire
        (lib.mkIf (isActive "R72" "reinforced" "base" [ ]) {

          # TODO: générer les règles rsyslogd par service DNF enregistré
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
        # sideEffects: I/O significatif (1-10% CPU sur workloads syscall-heavy)
        (lib.mkIf (isActive "R73" "reinforced" "base" [ "no-auditd" ]) {
          security.audit.enable = true;
          security.audit.rules = [

            # Appels système critiques
            "-a exit,always -F arch=b64 -S execve,execveat"
            "-a exit,always -F arch=b64 -S clock_settime -S settimeofday -S adjtimex"
            "-a exit,always -F arch=b64 -S sethostname -S setdomainname"
            "-a exit,always -F arch=b64 -S kexec_load -S kexec_file_load"

            # Fichiers sensibles
            "-w /etc/sudoers      -p wa"
            "-w /etc/sudoers.d/   -p wa"
            "-w /etc/passwd       -p wa"
            "-w /etc/shadow       -p wa"
            "-w /var/log/auth.log -p wa"

            # Rendre la configuration immuable (reboot requis pour changer les règles)
            "-e 2"
          ];
        })

      ]
    ))
  ];
}
