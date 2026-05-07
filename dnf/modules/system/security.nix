# Durcissement système ANSSI BP-028 v2.0 (GNU/Linux). (wip)
#
# Module recommandé, activé dans certains profils d'hosts ou manuellement en
# fonction des besoins. Applique progressivement les
# recommandations de l'ANSSI selon le niveau choisi et la catégorie machine.
# Chaque profil de host définit son niveau et sa catégorie :
#
# :::danger[Module en cours de développement]
# - Affiner et tester les options, fonctionnalités, etc.
# - Créer le "checkScript", outil d'introspection de la conf sécurité.
# - Conf locale simple, pour ce qui dépend du matériel et des besoins.
# :::
#
# ```nix
# darkone.system.security = {
#   level    = "intermediary"; # minimal | intermediary | reinforced | high
#   category = "server";       # base | client | server
# };
# ```
#
# Les règles incompatibles avec l'environnement s'excluent par tag :
#
# ```nix
# darkone.system.security.excludes = [ "needs-jit" "needs-hibernation" ];
# ```
#
# Une règle spécifique s'écarte avec une justification obligatoire :
#
# ```nix
# darkone.system.security.exceptions = {
#   R9.rationale = "Docker rootless requis en développement.";
# };
# ```
#
# :::note[Niveau de durcissement ANSSI]
# - `minimal`      : socle commun, tout système (défaut).
# - `intermediary` : recommandé pour la quasi-totalité des systèmes.
# - `reinforced`   : systèmes sensibles ou multi-tenants.
# - `high`         : compétences et budget dédiés ; implique la recompilation
#                    du noyau (tag `kernel-recompile`) si celui-ci n'est pas exclu.
# :::
#
# :::note[Catégorie machine]
# - `base`   : règles universelles, toujours appliquées (défaut).
# - `client` : poste utilisateur (GUI, USB, session, verrouillage).
# - `server` : serveur (réseau durci, journalisation centralisée, services exposés).
#
# Indépendant de `host.profile` — à définir explicitement dans chaque profil de host.
# :::
#
# :::note[Tags d'exclusion]
# - `kernel-recompile`             : ignore R15–R27, C1 (pas de noyau custom).
# - `disable-kernel-module-loading`: ignore R10 (peut casser des périphériques).
# - `no-ipv6`                      : ignore R13, R22 (désactivation IPv6).
# - `no-mac`                       : ignore R37, R45 (pas de MAC actif).
# - `no-sealing`                   : ignore R76, R77 (pas de HIDS/AIDE).
# - `no-auditd`                    : ignore R73 (auditd non configurable).
# - `embedded`                     : lève les contraintes /var, /home, etc.
# - `needs-jit`                    : autorise W^X relâché (Java, .NET, V8, Wasm).
# - `needs-kexec`                  : conserve kexec pour kdump.
# - `needs-binfmt`                 : conserve binfmt_misc (Java, qemu-static).
# - `needs-hibernation`            : conserve l'hibernation (laptops).
# - `needs-usb-hotplug`            : désactive USBGuard / deny_new_usb.
# :::
#
# :::note[Exceptions par règle]
# Une règle avec exception est exclue de l'activation même si le niveau la couvrirait.
# Justification obligatoire dans `rationale`.
# :::
#
# :::caution[Effets de bord]
# Certaines règles peuvent casser des usages courants : `noexec /tmp` (R28),
# SMT désactivé (R8), modules non signés (R18), containers rootless (R9),
# JIT (R63). Consulter les commentaires `sideEffects` dans chaque fichier
# thématique avant d'élever le niveau sur un système en production.
# :::

{ lib, network, ... }:
{
  options = {
    darkone.system.security = {
      enable = lib.mkEnableOption "Activer le module de durcissement ANSSI BP-028 v2.0.";

      level = lib.mkOption {
        type = lib.types.enum [
          "minimal"
          "intermediary"
          "reinforced"
          "high"
        ];
        default = "minimal";
        description = "Niveau de durcissement ANSSI ciblé.";
      };

      category = lib.mkOption {
        type = lib.types.enum [
          "base"
          "client"
          "server"
        ];
        default = "base";
        description = "Catégorie machine sélectionnant les sous-ensembles de règles.";
      };

      excludes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "kernel-recompile"
          "no-ipv6"
          "needs-usb-hotplug"
          "needs-jit"
        ];
        description = "Tags désactivant des groupes entiers de règles.";
      };

      exceptions = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.rationale = lib.mkOption {
              type = lib.types.lines;
              description = "Justification obligatoire pour désactiver cette règle spécifique.";
            };
          }
        );
        default = {

          # SELinux n'est pas supporté sur NixOS — exception structurelle
          R46.rationale = "SELinux is unsupported on NixOS.";
          R47.rationale = "SELinux is unsupported on NixOS.";
          R48.rationale = "SELinux is unsupported on NixOS.";
          R49.rationale = "SELinux is unsupported on NixOS.";
        };
        description = "Exceptions par règle avec justification obligatoire.";
      };

      # --- Options transverses (utilisées par plusieurs fichiers thématiques) ---

      adminMailbox = lib.mkOption {
        type = lib.types.str;
        default = "admin@${network.domain}";
        example = "admin@exemple.fr";
        description = "Adresse e-mail de l'administrateur (sudo R39, MTA aliases R75).";
      };

      useHardenedKernel = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Utiliser linuxPackages_hardened (R60, C1) à la place du noyau par défaut.";
      };

      allowedActiveUsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Liste exhaustive des comptes utilisateur actifs (validation R30).";
      };
    };
  };
}
