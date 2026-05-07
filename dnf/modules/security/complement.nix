# Mesures complémentaires transverses — Annexe A (C1–C12). (wip)
#
# Ces mesures n'ont pas de numéro ANSSI mais sont indispensables à l'esprit du
# guide. Couvre les patches linux-hardened (C1), Lockdown LSM (C2), USBGuard (C3),
# nftables deny-by-default (C4), SSH durci (C5), LUKS2 (C6), NTP/NTS (C7),
# DNS sécurisé (C8), core dumps désactivés (C9), anti brute-force PAM (C10),
# bannières légales (C11) et restriction cron/at (C12).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::note[Niveau Lockdown LSM (C2)]
# - `none` : pas de Lockdown.
# - `integrity` : interdit les modifications noyau via userspace.
# - `confidentiality` : idem + interdit la lecture de secrets noyau.
# :::
#
# :::caution[C2 — Lockdown LSM]
# `lockdown=confidentiality` interdit kexec, écriture /dev/mem, MSR, hibernation.
# Casse `dmidecode` sur certaines zones, `flashrom`, `i2c-tools`.
# :::
#
# :::caution[C4 — Egress filtering]
# La politique deny-by-default en sortie casse les outils qui joignent des CDN
# (curl, téléchargements noyau). Requis : un proxy HTTP(S) sortant maîtrisé.
# :::
#
# :::caution[C5 — SSH durci]
# Tunnels SSH, agent forwarding et X11 désactivés. Adapter les workflows admin
# vers ProxyJump (`ssh -J`). Ce module surcharge `core.nix` pour SSH.
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
    darkone.security.complement.enable = lib.mkEnableOption "Active les mesures ANSSI complémentaires (C1–C12).";

    darkone.security.complement.lockdownLevel = lib.mkOption {
      type = lib.types.enum [
        "none"
        "integrity"
        "confidentiality"
      ];
      default = "integrity";
      description = "Niveau Lockdown LSM (C2)";
    };

    darkone.security.complement.lsmStack = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "lockdown"
        "yama"
        "bpf"
        "landlock"
      ];
      description = "Ordre de la pile LSM (C2, R11, R20). Modifie boot.kernelParams lsm=...";
    };

    darkone.security.complement.ntpServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "time.cloudflare.com" ];
      description = "Serveurs NTP/NTS (C7).";
    };

    darkone.security.complement.useNts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Active NTS (Network Time Security) pour l'authentification NTP (C7).";
    };

    darkone.security.complement.sshBanner = lib.mkOption {
      type = lib.types.str;
      default = ''
        *** Accès réservé aux personnes autorisées ***
        Toute connexion est journalisée et peut faire l'objet de poursuites.
      '';
      description = "Bannière SSH affichée avant l'authentification (C11).";
    };

    darkone.security.complement.cronAllowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "root" ];
      description = "Utilisateurs autorisés à planifier des tâches cron (C12).";
    };

    darkone.security.complement.egressAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "IP/CIDR autorisés en sortie pour le filtrage egress nftables strict (C4).";
    };
  };

  config = lib.mkMerge [
    { darkone.security.complement.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # C1 — Patches linux-hardened (high, tag: kernel-recompile)
        # Géré par kernel-build.nix via mainSecurityCfg.useHardenedKernel = true
        # Sysctls spécifiques linux-hardened
        (lib.mkIf (isActive "C1" "high" "base" [ "kernel-recompile" ] && mainSecurityCfg.useHardenedKernel)
          {
            boot.kernelParams = [ "extra_latent_entropy" ];
            boot.kernel.sysctl = {
              "kernel.tiocsti_restrict" = 1; # Restreint l'injection artificielle de caractères dans le terminal.
              "kernel.device_sidechannel_restrict" = 1; # Restreint les accès non privilégiés aux infos périphériques / perfs.
              "kernel.perf_event_paranoid" = 3; # Sémantique étendue en linux-hardened - contrôle l'accès à perf.
            }
            // lib.optionalAttrs (!lib.elem "needs-usb-hotplug" mainSecurityCfg.excludes) {

              # Empêche l’ajout de nouveaux périphériques USB après le boot ou après activation du paramètre
              "kernel.deny_new_usb" = lib.mkIf (mainSecurityCfg.category == "client") 1;
            };
          }
        )

        # C2 — Lockdown LSM - Linux Security Module (high)
        # sideEffects: interdit kexec, /dev/mem, MSR, hibernation, certaines lectures noyau
        (lib.mkIf (isActive "C2" "high" "base" [ ]) {
          boot.kernelParams = [
            "lsm=${lib.concatStringsSep "," cfg.lsmStack}"
          ]
          ++ lib.optional (cfg.lockdownLevel != "none") "lockdown=${cfg.lockdownLevel}";
        })

        # C3 — USBGuard (reinforced, client + server recommandé, tag: needs-usb-hotplug)
        # sideEffects: tout nouveau périphérique USB bloqué sans whitelist préalable
        (lib.mkIf (isActive "C3" "reinforced" "client" [ "needs-usb-hotplug" ]) {
          services.usbguard = {
            enable = true;

            # Politique implicite : bloquer tout périphérique non déclaré
            implicitPolicyTarget = "block";

            # TODO: générer le ruleset depuis les périphériques validés à l'installation
            # rules = '' allow id ... '' ;
          };
        })

        # C4 — nftables avec politique deny-by-default (minimal → reinforced)
        # sideEffects: egress filtering casse curl/téléchargements si pas de proxy sortant
        (lib.mkIf (isActive "C4" "minimal" "base" [ ]) {
          networking.nftables.enable = true;
          networking.firewall.enable = true;

          # Politique deny-by-default : aucun port ouvert sauf déclaration explicite
          networking.firewall.allowedTCPPorts = lib.mkDefault [ 22 ];

          # Egress filtering (niveau reinforced seulement)
          # TODO: chaîne output deny + allowlist via cfg.egressAllowlist
        })

        # C5 — Durcissement OpenSSH (intermediary, base)
        # sideEffects: tunnels, agent forwarding et X11 désactivés
        # NOTE : surcharge la config SSH de core.nix (ce module est obligatoire selon Q3)
        (lib.mkIf (isActive "C5" "intermediary" "base" [ ]) {
          services.openssh = {

            # Ne pas désactiver SSH ici — core.nix l'active, on durcit seulement
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

              # Algorithmes conformes ANSSI-NT-007
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

        # C6 — Chiffrement disque LUKS2 (intermediary laptop, reinforced serveur)
        # sideEffects: performances disque -5-15%, impossible d'extraire sans clé
        (lib.mkIf (isActive "C6" "intermediary" "base" [ ]) {

          # La configuration LUKS est déclarée dans disko.nix (hors périmètre de ce module)
          # Ce module vérifie uniquement que le swap est chiffré si présent
          swapDevices = lib.mkIf (config.swapDevices != [ ]) (
            map (
              swap:
              swap
              // lib.optionalAttrs (!(swap.randomEncryption.enable or false)) { randomEncryption.enable = true; }
            ) config.swapDevices
          );

          # TODO: assertion vérifiant que / ou /home est sur LUKS (via blkid dans checkScript)
        })

        # C7 — Synchronisation horaire NTS (intermediary, base)
        # sideEffects: NTS requiert serveurs compatibles, trafic UDP/123 + TCP/4460
        (lib.mkIf (isActive "C7" "intermediary" "base" [ ]) {
          services.chrony = {
            enable = true;
            servers = cfg.ntpServers;
            extraConfig = lib.optionalString cfg.useNts ''
              ${lib.concatMapStringsSep "\n" (s: "server ${s} nts") cfg.ntpServers}
            '';
          };
        })

        # C8 — Résolveur DNS sécurisé DNSSEC + DoT (intermediary, base)
        # sideEffects: zones internes non-DNSSEC nécessitent Domains=~example.internal
        (lib.mkIf (isActive "C8" "intermediary" "base" [ ]) {
          services.resolved = {
            dnssec = "true";
            dnsovertls = "true";
            fallbackDns = [ ]; # Pas de fallback DNS en clair
          };
        })

        # C9 — Désactivation des core dumps (reinforced, base)
        # sideEffects: analyse post-mortem impossible sans environnement dédié
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

        # C10 — Anti brute-force et limites session (intermediary, base)
        # sideEffects: attaquant peut déclencher lock-out volontaire (DoS compte)
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

        # C11 — Bannières et messages légaux (minimal, base)
        # sideEffects: aucun
        (lib.mkIf (isActive "C11" "minimal" "base" [ ]) {
          environment.etc."issue".text = cfg.sshBanner;
          environment.etc."issue.net".text = cfg.sshBanner;
        })

        # C12 — Restriction cron/at (minimal, base)
        # sideEffects: utilisateurs non listés ne peuvent plus planifier de tâches
        (lib.mkIf (isActive "C12" "minimal" "base" [ ]) {

          # Liste blanche cron
          environment.etc."cron.allow".text = lib.concatStringsSep "\n" cfg.cronAllowedUsers + "\n";

          # Bloquer tous les autres
          environment.etc."cron.deny".text = "ALL\n";

          # TODO: at.allow via services.atd si activé
        })
      ]
    ))
  ];
}
