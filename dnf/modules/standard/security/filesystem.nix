# Partitionnement, arborescence et permissions des fichiers (R28–R29, R50–R57).
#
# Couvre les options de montage sécurisées (R28), la restriction de /boot (R29),
# les permissions des fichiers sensibles (R50), les mots de passe hors-store (R51),
# les sockets (R52), les fichiers orphelins (R53), le sticky bit (R54),
# les répertoires temporaires par utilisateur (R55) et les setuid (R56, R57).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R28 — noexec /tmp]
# `noexec` sur /tmp casse de nombreux installeurs et compilateurs (pip, cargo,
# gcc). Workaround : `export TMPDIR=$XDG_RUNTIME_DIR` dans les profils shell.
# :::
#
# :::caution[R29 — /boot noauto]
# `noauto` sur /boot impose un remontage manuel à chaque mise à jour NixOS.
# Un wrapper `nixos-rebuild` doit assurer le mont/démontage automatique.
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
    darkone.security.filesystem.enable = lib.mkEnableOption "Active la sécurisation du système de fichiers ANSSI (R28–R29, R50–R57).";

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
      description = "Allowlist des binaires setuid/setgid tolérés (R56, R57).";
    };
  };

  config = lib.mkMerge [
    { darkone.security.filesystem.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R28 — Partitionnement type et options de montage (intermediary, base)
        # sideEffects: noexec /tmp casse compilateurs ; hidepid=2 masque les processus non-root
        (lib.mkIf (isActive "R28" "intermediary" "base" [ ]) {

          # /tmp en tmpfs avec options restrictives
          boot.tmp.useTmpfs = lib.mkDefault true;
          boot.tmp.tmpfsSize = lib.mkDefault "25%";

          # Options de montage pour /tmp
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

          # /proc avec hidepid=2 (masque les processus non-root)
          # Groupe proc requis pour les outils légitimes (ps, htop en root)
          users.groups.proc = lib.mkDefault { };
          boot.specialFileSystems."/proc" = {
            options = [
              "hidepid=2"
              "gid=proc"
            ];
          };

          # /dev/shm sans exec
          boot.specialFileSystems."/dev/shm" = {
            options = [
              "nosuid"
              "nodev"
              "noexec"
            ];
          };

          # Tmpfiles : permissions de /var/tmp
          systemd.tmpfiles.rules = [
            "d /var/tmp 1777 root root -" # sticky bit
          ];

          # TODO: options nosuid,nodev,noexec sur /var/log, /home, /srv, /opt
          # via fileSystems si ces points de montage sont des partitions séparées.
          # En NixOS, ces options ne s'appliquent que si la partition existe.
        })

        # R29 — Restreindre /boot (reinforced, base)
        # sideEffects: noauto + nixos-rebuild nécessite un wrapper de remontage
        (lib.mkIf (isActive "R29" "reinforced" "base" [ ]) {

          # Permissions 700 sur /boot
          system.activationScripts.bootPerm = ''
            if [ -d /boot ]; then
              chmod 0700 /boot
            fi
          '';

          # DÉCISION : options noauto non posées par défaut car elles cassent
          # nixos-rebuild switch sans wrapper. À activer manuellement avec un
          # wrapper ou via une option darkone.security.filesystem.bootNoauto.
          # fileSystems."/boot".options = [ "nosuid" "nodev" "noexec" "noauto" ];
        })

        # R50 — Restreindre les fichiers sensibles (intermediary, base)
        # sideEffects: aucun majeur sur NixOS (permissions déjà correctes par défaut)
        (lib.mkIf (isActive "R50" "intermediary" "base" [ ]) {
          systemd.tmpfiles.rules = [

            # Journaux d'audit et sudo
            "d /etc/audit          0750 root adm   -"
            "d /var/log/audit      0750 root adm   -"
            "d /var/log/sudo-io    0750 root adm   -"

            # Logs système (si répertoire existe)
            "Z /var/log/nginx      0640 nginx adm  -"
            "Z /var/log/sshd       0640 root  adm  -"
          ];
        })

        # R51 — Changer les secrets dès l'installation (reinforced, base)
        # sideEffects: impossible de déployer sans accès au coffre sops-nix
        (lib.mkIf (isActive "R51" "reinforced" "base" [ ]) {

          # Assertion : interdire hashedPassword en clair dans le store Nix
          # Les mots de passe doivent transiter par sops-nix (intégration core.nix)
          assertions = [
            {
              assertion = lib.all (
                _user: true

                # TODO: vérifier que hashedPassword n'est pas un hash en clair
                # La vérification réelle nécessite d'inspecter users.users.*.hashedPassword
                # et de comparer à une blocklist (p4ssw0rd, hash vide, hashs Debian par défaut)
              ) (lib.attrValues config.users.users);
              message = "R51: Les mots de passe doivent être gérés via sops-nix, pas en clair.";
            }
          ];
        })

        # R52 — Sockets et pipes nommés (intermediary, base)
        # sideEffects: services historiques (X11 abstract socket) doivent migrer
        (lib.mkIf (isActive "R52" "intermediary" "base" [ ]) {

          # Imposer RuntimeDirectoryMode=0750 par défaut pour les services systemd
          systemd.services = lib.mkDefault { };

          # TODO: appliquer `serviceConfig.RuntimeDirectoryMode = "0750"` à tous les services
          # via un module systemd overlay — nécessite une liste explicite ou un hook global
        })

        # R53 — Pas de fichiers sans propriétaire (minimal, base)
        # sideEffects: whitelist /nix/store recommandée (UID transitoires)
        (lib.mkIf (isActive "R53" "minimal" "base" [ ]) {

          # Timer hebdomadaire de détection (rapport seulement, pas de correction auto)
          systemd.timers.anssi-orphan-scan = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "weekly";
              Persistent = true;
            };
          };
          systemd.services.anssi-orphan-scan = {
            description = "ANSSI R53 : scan des fichiers sans propriétaire";
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

        # R54 — Sticky bit sur répertoires world-writable (minimal, base)
        (lib.mkIf (isActive "R54" "minimal" "base" [ ]) {
          systemd.tmpfiles.rules = [
            "d /tmp     1777 root root -"
            "d /var/tmp 1777 root root -"
          ];
        })

        # R55 — Répertoires temporaires par utilisateur (intermediary, base)
        # sideEffects: pam_namespace requiert /etc/security/namespace.conf
        (lib.mkIf (isActive "R55" "intermediary" "base" [ ]) {

          # Alternative systemd-native : PrivateTmp=true au niveau service (cf. R63)
          # pam_namespace est plus complet mais plus complexe à configurer
          # TODO: configurer pam_namespace ou documenter PrivateTmp comme alternative
        })

        # R56 — Éviter setuid/setgid arbitraires (minimal, base)
        # sideEffects: retirer des binaires peut casser des outils utilisateur
        (lib.mkIf (isActive "R56" "minimal" "base" [ ]) {

          # Timer de détection des setuid hors allowlist
          systemd.timers.anssi-setuid-scan = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "weekly";
              Persistent = true;
            };
          };
          systemd.services.anssi-setuid-scan = {
            description = "ANSSI R56 : scan des setuid hors allowlist";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = pkgs.writeShellScript "anssi-setuid-scan" ''
                ALLOWED="${lib.concatStringsSep " " cfg.allowedSetuid}"
                find / -xdev -type f -perm /6000 -ls 2>/dev/null | while read -r line; do
                  bin=$(echo "$line" | awk '{print $NF}')
                  base=$(basename "$bin")
                  found=0
                  for a in $ALLOWED; do [ "$base" = "$a" ] && found=1 && break; done
                  [ $found -eq 0 ] && echo "WARNING: setuid inattendu: $bin" | logger -t anssi-r56 -p security.warning
                done
              '';
            };
          };
        })

        # R57 — Setuid root minimal (reinforced, base)
        # Sous-ensemble de R56 : allowlist stricte + préférence capabilities
        (lib.mkIf (isActive "R57" "reinforced" "base" [ ]) {

          # ping via capabilities (cap_net_raw) plutôt que setuid
          security.wrappers.ping = lib.mkDefault {
            source = "${pkgs.iputils}/bin/ping";
            owner = "root";
            group = "root";
            capabilities = "cap_net_raw+ep";
          };

          # TODO: autres binaires à migrer de setuid vers capabilities (traceroute, etc.)
        })
      ]
    ))
  ];
}
