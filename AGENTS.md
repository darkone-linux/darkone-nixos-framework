# Contexte du projet pour agents IA

## Architecture

- `dnf/` : le framework NixOS (Code NIX commun à toutes les installations, NixOS et home-manager)
  - `dnf/modules` : modules NixOS
  - `dnf/lib` : librairie de code NIX complémentaire, accessible en important `dnfLib`
  - `dnf/home` : modules et profiles home-manager (sauf `home/nixos` qui contient du code NixOS à charger si tel ou tel profil home manager est présent sur la machine)
  - `dnf/tests` : tests unitaires (todo) et scripts de génération des VMs de tests pour tests de recette (todo)
  - `dnf/hosts` : code nix pour générer l'ISO d'installation des machines du réseau et les configurations disko
  - `dnf/dotfiles` et `dnf/assets` : fichiers non-nix utiles
- `src/` : générateur -> génère : 
  - du code Nix dans `var/generated` (hosts.nix, network.nix, users.nix) à partir de `usr/config.yaml`
  - les fichiers d'inclusion `default.nix`
  - la configuration initiale des nouvelles machines `usr/machines` et nouveaux utilisateurs `usr/users`.
  - la documentation des modules dans `doc/src/content/docs/ref/modules.mdx`
- `usr/` : configuration d'une installation
  - `usr/config.yaml` est la configuration haut niveau du réseau (machines, utilisateurs, services, etc.) -> NE PAS MODIFIER sans avis
  - `usr/modules`, `usr/home` surchargent et complètent respectivement `dnf/modules` et `dnf/home`
  - `usr/machines` contient les configurations spécifiques de chaque machine (hôte du réseau) déclaré dans `config.yaml`
  - `usr/users` contient les configurations spécifiques de chaque utilisateur déclaré dans `config.yaml`
  - `usr/secrets` contient les secrets sops -> NE PAS MODIFIER sans avis
- `var/` : données variables et générées (code nix généré, logs)
- `doc/` : documentation starlight
- `.trash/` : le code non utilisé mais qui pourrait être ré-utilisé plus tard (respecter la structure des dossiers / fichiers de provenance)

## Stack technique

- NixOS flakes + home-manager + colmena pour la configuration générale du réseau, machines, services, utilisateurs
- sops-nix pour les secrets
- disko + nixos-anywhere pour l'installation de nouvelles machines NixOS pilotées par le projet
- PHP (générateur dans `src`) → cible : Rust
- Just pour les tâches d'administration et de maintenance

## Règles absolues

- Ne jamais modifier `usr/config.yaml` ni les fichiers sops et tout ce qui se trouve dans `usr/secrets`
- Toujours valider avec `just clean` et `just check-flake` avant de proposer un commit
- Nettoyer et tester avec `just clean` après chaque modification **Nix**
- Si un fichier nix est ajouté, supprimé ou modifié, toujours faire un `just generate` pour régénérer les fichiers `default.nix` d'inclusion

## Conventions de code Nix

- Les options des modules suivent la convention `darkone.services.<nom-du-module>.<option>` (ex: `darkone.services.adguardhome.enable`)
- Les modules de services dans `(dnf|usr)/modules/standard/service` doivent être déclarés via `dnf/modules/system/services.nix`
- Préférer `lib.mkIf` à `if/then/else` dans les définitions d'attributs

## Fichiers à ne jamais modifier directement

- `usr/config.yaml` et `usr/secrets/` → gérés par l'admin humain
- `var/generated/` → généré automatiquement par `just generate`, toute modification sera écrasée
- `var/` → fichiers variables susceptibles d'être écrasés ou supprimés
- `flake.lock` → ne mettre à jour que via `nix flake update` + validation
- `dnf/assets/` et `dnf/dotfiles/` → sauf demande explicite
- Les fichiers `default.nix` désignés par les sous-commandes `_gen-default` de `just generate`, ces fichiers sont automatiquement mis à jour avec cette commande
- Tous les fichiers `hardware-configuration.nix`
- Tous les fichiers dont le commentaire d'entête précise qu'il ne faut pas les modifier

## Fichiers importants à connaître

- `flake.nix` → flake nixos du projet, optimisé pour colmena : dépendances, version de nixpkgs, inputs et outputs
- `Justfile` → toutes les macro-commandes importantes pour la maintenance
- `usr/config.yaml` → configuration principale, à lire mais ne pas modifier
- `README.md` et `README.fr.md` → présentation du projet et liste TODO dans la version fr
- `dnf/modules/standard/system/services.nix` → les modules de type "service" dépendent de ce fichier
- `var/generated/*.nix` → toutes les données importantes issues de config.yaml, massivement utilisées dans les modules nixos et home-manager
  - `hosts.nix` → toutes les machines du réseau et leurs caractéristiques
  - `users.nix` → tous les utilisateurs du réseaux, leurs groupes et caractéristiques
  - `network.nix` → paramètres du réseau et des zones (sous-réseaux)

## Workflow attendu des agents

1. Lire les fichiers concernés AVANT toute modification
2. Proposer les changements et expliquer le raisonnement
3. Modifier les fichiers
4. Exécuter `just clean` pour formatter et valider la syntaxe (format + check statix/deadnix)
5. En cas d'erreur de `just clean`, analyser la sortie, corriger l'erreur et réexécuter l'étape précédente. Ne pas boucler plus de 5 fois.
6. Exécuter `just check-flake` pour valider le flake complet
7. Résumer les changements effectués et proposer un court intitulé pour le commit

## Commandes utiles (Justfile)

IMPORTANT : toutes les commandes just qui ne sont pas listées ici sont interdites.

Justfile à la racine :

- `just clean` → generate + format + check statix + deadnix (à faire après chaque modif Nix)
- `just check-flake` → validation complète du flake
- `just generate` → regénère `var/generated/` depuis `usr/config.yaml`
- `just format` → nixfmt récursif
- `just check` → deadnix + statix

Justfile dans `doc/` : pour le moment l'utilisation de ces commandes est interdit.

## Glossaire

- **DNF** : Darkone NixOS Framework (ce projet)
- **flake** : unité de configuration NixOS reproductible (`flake.nix`)
- **host / machine** : une machine physique ou VM configurée par DNF
- **profil (home-manager)** : ensemble d'options pré-configurées (ex: profil `gamer`, `admin`)
- **colmena** : outil de déploiement multi-host NixOS
- **disko** : partitionnement déclaratif NixOS avec l'outil disko
- **sops** : gestion des secrets chiffrés (fichiers `.yaml` dans `usr/secrets/`)
- **home-manager** : gestion de la config utilisateur (dotfiles, apps) via Nix
- **dnfLib** : bibliothèque de fonctions Nix internes au projet (`dnf/lib/`)

## Le générateur (`src/`)

Le générateur lit `usr/config.yaml` et produit :

- `var/generated/hosts.nix` : liste des machines et leurs paramètres réseau
- `var/generated/network.nix` : configuration réseau globale
- `var/generated/users.nix` : liste des utilisateurs et leurs associations machines
- Les `default.nix` d'inclusion dans les dossiers concernés
- Les squelettes de config dans `usr/machines/<host>/` et `usr/users/<user>/`
- La documentation des modules dans `doc/src/content/docs/ref/modules.mdx`

### Pour la réécriture Rust

- Le comportement du générateur PHP est la référence.
- Les outputs doivent être bit-for-bit identiques (ou documentés si améliorés).
- Commencer par une phase d'analyse/documentation avant tout code.
- L'analyseur NIX doit être remplacé par un véritable parseur nix (lecture des options de modules et commentaires).

## Périmètres par type de tâche

| Tâche | Fichiers autorisés en écriture | Interdits |
|---|---|---|
| Amélioration modules Nix | `dnf/modules/`, `dnf/lib/`, `dnf/home/` | `usr/`, `var/generated/` |
| Tests unitaires | `dnf/tests/` | Tout le reste |
| Réécriture générateur Rust | `src/` (nouveau dossier Rust) | `src/` PHP tant que non validé |
| Traductions | `README.md`, `README.fr.md`, `doc/` | Tout le reste |
| Mise à jour flake | `flake.nix`, `flake.lock` | Tout le reste |
| Config machines/users | `usr/machines/`, `usr/users/` | `usr/config.yaml`, `usr/secrets/` |

## Stratégie de tests (en cours de mise en place)

- **Tests unitaires** (`dnf/tests/unit/`) : avec `nix-unit`, tester les fonctions de `dnfLib` et la logique des modules (évaluation Nix pure, sans VM)
- **Tests de recette** (`dnf/tests/vms/`) : avec `nixosTest`, démarrer des VMs NixOS minimales qui activent un ou plusieurs modules et vérifient leur comportement
- Les tests unitaires sont prioritaires et moins coûteux à écrire/exécuter
- Nommer les tests : `test-<chemin>-<nom-du-fichier>.nix`, exemple pour dnf/modules/standard/system/core.nix -> test-dnf-modules-standard-system-core.nix
