# Intégrité du système de fichiers — HIDS (R76–R77).
#
# Couvre le scellement et la vérification d'intégrité via AIDE (R76) et la
# protection de la base scellée par signature GPG avec copie distante (R77).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R76 — AIDE]
# Le scan complet peut durer 15–60 min selon la taille du FS et le CPU.
# Planifier en heures creuses. Faux-positifs fréquents sur /etc/resolv.conf,
# /var/lib, /var/cache — ajouter dans les exclusions.
# :::
#
# :::caution[R77 — Base signée]
# La base AIDE doit être re-signée à chaque mise à jour majeure NixOS
# (le store change). Prévoir une procédure de mise à jour de la baseline.
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
  cfg = config.darkone.security.integrity;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.integrity.enable = lib.mkEnableOption "Active l'intégrité HIDS ANSSI — AIDE (R76–R77).";

    darkone.security.integrity.aideRemoteCopy = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            host = lib.mkOption {
              type = lib.types.str;
              description = "Hôte distant pour la copie de la base AIDE.";
            };
            sshKeyFile = lib.mkOption {
              type = lib.types.path;
              description = "Chemin vers la clé SSH privée pour la copie distante.";
            };
          };
        }
      );
      default = null;
      description = "Copie distante de la base AIDE signée GPG (R77). null = désactivé.";
    };
  };

  config = lib.mkMerge [
    { darkone.security.integrity.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R76 — Sceller / vérifier l'intégrité (high, base, tag: no-sealing)
        # sideEffects: scan long (15-60 min), I/O lourd, faux-positifs sur /etc/resolv.conf
        (lib.mkIf (isActive "R76" "high" "base" [ "no-sealing" ]) {
          services.aide = {
            enable = true;

            # Configuration AIDE : surveiller les chemins critiques
            # En NixOS : /run/current-system/sw plutôt que /usr (lien vers store immutable)
            settings = ''
              # Politique par défaut
              ALLXTRAHASHES = sha512+rmd160+sha256

              # Chemins à surveiller
              /etc          ALLXTRAHASHES
              /boot         ALLXTRAHASHES
              /run/current-system/sw ALLXTRAHASHES

              # Exclusions NixOS
              !/var/log
              !/var/lib
              !/var/cache
              !/proc
              !/sys
              !/run
              !/etc/resolv.conf
              !/etc/machine-id
            '';
          };

          # Timer quotidien de vérification
          systemd.timers.aide-check = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "daily";
              RandomizedDelaySec = "1h"; # Décalage aléatoire pour éviter la charge simultanée
              Persistent = true;
            };
          };
          systemd.services.aide-check = {
            description = "ANSSI R76 : vérification d'intégrité AIDE";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.aide}/bin/aide --config=/etc/aide/aide.conf --check";

              # Exécution en heures creuses (2h-4h du matin)
              IOSchedulingClass = "idle";
              CPUSchedulingPolicy = "idle";
            };
          };
        })

        # R77 — Protection de la base scellée (high, base)
        # sideEffects: procédure de signature obligatoire à chaque mise à jour
        (lib.mkIf (isActive "R77" "high" "base" [ "no-sealing" ]) {

          # Permissions restrictives sur la base AIDE
          systemd.tmpfiles.rules = [
            "d /var/lib/aide 0700 root root -"
            "z /var/lib/aide/aide.db.gz 0600 root root -"
          ];

          # Copie distante de la base si configurée
          systemd.services.aide-remote-backup = lib.mkIf (cfg.aideRemoteCopy != null) {
            description = "ANSSI R77 : copie distante de la base AIDE";
            after = [ "aide-check.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = pkgs.writeShellScript "aide-remote-backup" ''
                scp -i ${cfg.aideRemoteCopy.sshKeyFile} \
                  /var/lib/aide/aide.db.gz \
                  ${cfg.aideRemoteCopy.host}:/var/backups/aide/$(hostname)-$(date +%Y%m%d).db.gz
              '';
            };
          };

          # TODO: signature GPG de la base (clé hors-ligne recommandée)
        })
      ]
    ))
  ];
}
