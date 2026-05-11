# Stratégie de staging — Stack de tests DNF

Document de référence décrivant la **stack technologique** retenue pour les tests d'intégration multi-machines de la conf DNF. Les détails d'implémentation (arborescence, modules, intégration au `just`-flow, agents spécialisés, schéma des rapports) sont définis dans des plans ultérieurs.

## Contexte

La conf DNF intègre plusieurs types de machines (serveurs, gateways, headscale, postes de travail). Avant chaque évolution structurante, il faut pouvoir :

- **Monter un réseau virtuel reproductible** simulant la topologie réelle (subnets, gateways, mesh tailscale)
- **Exécuter des recettes de test** : SSH, services, sessions graphiques
- **Collecter logs et artefacts** (boot, journald, screenshots)
- **Faire analyser ces artefacts par des agents IA multi-providers** qui produisent des rapports d'erreurs/warnings exploitables

L'existant fournit déjà :

- Des **tests unitaires Nix** (`dnf/tests/unit/lib/*_test.nix`) exécutés via `nix-unit --flake .#libTests` (recette `just unit-tests`)
- Des **scripts shell de provisioning VirtualBox** (`dnf/tests/vms-{headscale,vbox}-create.sh`) qui créent un mini-lab manuel (gateway / headscale / node, ou pool de 10 VMs).

La première première brique doit être intégrée au L1, la seconde **remplacée** au L3 (voir plus bas).

## Vue d'ensemble — 3 niveaux de tests

| Niveau | Nom              | Objectif                                                  | Commande just                   | État    |
|--------|------------------|-----------------------------------------------------------|---------------------------------|---------|
| **L1** | Unitaires        | Tester les helpers Nix (`dnf/lib/`) de manière isolée     | `just test [<what>]`            | Existant — à renommer |
| **L2** | Simulation éphémère | Recettes reproductibles : réseaux virtuels, recettes auto, intégrables CI | `just simulate [<what>]`       | À créer |
| **L3** | Lab persistant   | Réseau virtuel inspectable manuellement (SSH, GUI, debug long) | `just launch-lab [<what>]`     | À créer (remplace les scripts VBox) |

Le paramètre `<what>` est optionnel pour les trois niveaux :

- **L1** : cible un module de test (ex : `lib/strings`, `lib/srv`) ou tous si omis
- **L2** : cible un scénario ou une famille (ex : `headscale-mesh`, `gateway`, `install/<host>`) ou tous si omis. **Deux familles de scénarios** cohabitent en L2 : *runtime* (la conf en marche, en réseau) et *install* (le pipeline `disko + nixos-anywhere`)
- **L3** : cible une partie du lab (ex : `gateway`, `headscale`, `workstation-kde`, `full`) ou un profil par défaut si omis

## Stack technologique

### L1 — Tests unitaires (existant)

**`nix-unit`** sur `flake.nix#libTests` :

- Sources : `dnf/tests/unit/default.nix` + `dnf/tests/unit/lib/*_test.nix`
- Couvre les helpers de `dnf/lib/` (règle AGENTS.md : chaque helper doit avoir un test unitaire ici)
- Recette actuelle : `just unit-tests` → **à renommer `just test [<what>]`** (alias ou recette dédiée à décider)
- Avec `<what>` : passer un filtre à `nix-unit` (ex : ne lancer que `lib/strings`)

### L2 — Simulation éphémère reproductible

**NixOS Test Driver** (`pkgs.testers.runNixOSTest`) — cœur du système de recettes automatisées :

- Multi-machines déclaratives à partir des modules NixOS existants (réutilise `usr/machines/*` et `dnf/modules/`)
- VLANs virtuels via `virtualisation.vlans` (topologie complète : subnets, gateways, NAT)
- Logs : `machine.get_unit_log("service-name")`, `machine.succeed/fail`, `machine.wait_for_unit`
- GUI : `machine.screenshot()`, `machine.wait_for_text()`, `machine.get_screen_text()` (OCR tesseract intégré)
- Mode interactif : `nix build .#checks.<system>.<test>.driverInteractive` pour debug pas-à-pas
- Exposé via `flake.nix#checks.<system>.<scenario>` → également pris en compte par `just check-flake`
- Recette dédiée `just simulate [<what>]` qui sélectionne le ou les checks à exécuter et capture les artefacts (logs, screenshots) pour la couche d'analyse IA

**Défi clé — autonomie des machines** : chaque machine doit pouvoir être instanciée dans le test driver **quelle que soit sa catégorie** (poste de travail, serveur, gateway, headscale), **sans dépendre du `usr/config.yaml` global** ni du pipeline de secrets sops complet. Pistes :

- Identifier dans `dnf/modules/` les modules qui font des hypothèses globales (présence d'un voisin réseau, d'un secret sops, d'une entrée dans `config.yaml`) et les rendre **désactivables ou stubbables** via une option `darkone.test.standalone = true` (ou équivalent)
- Fournir des **fixtures** (config minimale, faux secrets, faux voisins) injectables au niveau du test
- Documenter les dépendances inter-machines qui doivent rester réelles (ex : un test du mesh tailscale doit garder un vrai `headscale` voisin)

**Tests d'installation (catégorie de scénarios dédiée)** :

- Cible : valider le pipeline complet **disko → nixos-anywhere → premier boot**, qui n'est **pas** exercé par L3 (microvm.nix utilise des images bakées au build time, sans partitionnement réel)
- Outil sous-jacent : `nixos-anywhere --flake .#<host> --vm-test`, déjà invoqué par la recette existante `just install <host> do=test` (`Justfile:362-363`)
- Recettes : `just simulate install` (toutes les machines), `just simulate install/<host>` (une seule)
- Réutilise le `disko.nix` réel de chaque machine (`usr/machines/<host>/disko.nix`) → valide aussi la cohérence des configs disko
- Sortie : logs d'install + état post-reboot capturés, transmis au pipeline d'analyse IA

### L3 — Lab persistant inspectable

**microvm.nix** avec hyperviseur **QEMU** :

- VMs en systemd services, état persistant entre runs
- QEMU choisi pour compatibilité GUI (postes KDE/GNOME nécessitent un display)
- Inspection manuelle : SSH, VNC, accès console
- Networking : bridges/tap, peut reproduire la topologie des scénarios L2
- **Remplace** les scripts shell VirtualBox actuels (`dnf/tests/vms-{headscale,vbox}-{create,purge}.sh`) : ces scripts sont conservés temporairement comme référence, puis supprimés une fois le L3 opérationnel

**Architecture — projet de test parallèle à `usr/`** : plutôt que de réinventer la chaîne d'installation, le lab réutilise au maximum les outils existants (`just install`, `just configure`, `nixos-anywhere`, `disko`, `colmena`, `sops`). Le lab est traité comme **une instance DNF à part entière**, isolée du projet de production :

1. **Projet dédié** : un répertoire parallèle à `usr/` (par exemple `dnf/tests/lab/usr-test/`) contient un `config.yaml` propre aux tests (machines virtuelles, leurs rôles, leur topologie).
2. **Secrets dédiés** : génération automatique d'une **clé d'infra de test** (`age-keygen`) et d'un fichier `secrets.yaml` dédié, ré-utilisant la mécanique sops existante (`just configure-admin-host` adaptée).
3. **Provisioning des VMs** : par défaut, microvm.nix construit les images au build time avec la conf NixOS déjà bakée — pas de pipeline d'installation exercé ici (c'est le rôle des scénarios `simulate install/*` en L2). La VM démarre directement avec sa conf, sans `nixos-anywhere` ni `disko` réels.
4. **Hooks post-création — commandes dynamiques** : certaines actions ne sont pas (encore) déclaratives et doivent être scriptées après le boot. Exemples :
   - Enregistrement d'un nœud sur le serveur headscale (`headscale nodes register`)
   - Injection initiale de tokens, échange de clés tailscale, peering manuel
   - Premier login utilisateur, déclenchement de services lazy
   Ces hooks sont définis par scénario dans le projet de test, exécutés via SSH ou `colmena exec`.
5. **Introspection / test / analyse** : une fois le lab up, les recettes peuvent piloter les machines (SSH, captures d'écran via VNC, récupération de logs) et envoyer les artefacts au pipeline d'analyse IA.
6. **Mise à jour de la conf après premier boot** : deux mécanismes au choix par scénario :
   - **Par défaut — rebuild microvm.nix** (`microvm -u <name>`) : reconstruit l'image NixOS et redémarre la VM. Rapide, idiomatique, déclaratif pur.
   - **Optionnel — colmena via SSH** : `colmena apply --on <lab-host>` traite la VM comme un hôte de prod (sshd exposé). Permet de tester aussi le pipeline de déploiement réel utilisé par `just apply` (`Justfile:518-526`) en prod.

**Recette `just launch-lab [<what>]`** :

- `<what>` désigne un profil de lab (ex : `gateway`, `headscale`, `workstation-kde`, `full`)
- Démarre les VMs concernées, applique les hooks dynamiques, affiche les infos de connexion (IP, ports SSH/VNC)
- Recettes pendantes à prévoir lors de l'implémentation : `just stop-lab`, `just purge-lab`, `just lab-status`, `just lab-test [<what>]` (lance les recettes d'analyse sur un lab déjà up), `just lab-apply <what> [--via-colmena]` (applique une mise à jour de conf, rebuild microvm par défaut ou colmena en opt-in)

### Analyse GUI (commune L2/L3)

**OCR classique (tesseract)** via le test driver :

- `wait_for_text` / `get_screen_text` natifs
- Déterministe, gratuit, suffisant pour assertions UI ciblées
- Pas de LLM vision en première intention (coût + variabilité)

### Orchestration agents IA (commune L2/L3)

**Python pur**, sans nixai ni framework agentique lourd :

- **LiteLLM** : abstraction multi-provider (Claude / OpenAI / Ollama local / Groq…)
- **pydantic-ai** : agents avec contrats typés
- **instructor** : extraction structurée validée (rapports JSON exploitables)
- Pattern visé : agents spécialisés (boot, services, réseau, GUI) qui produisent chacun un rapport partiel, agrégés en rapport consolidé
- Boucle de correction auto repoussée à v2 (d'abord : rapports → patterns d'erreurs récurrents → puis auto-fix ciblé)
- Lancement déclenché automatiquement en fin de `just simulate` et de `just launch-lab` (ou recette dédiée pour relance sur artefacts existants)

## Difficultés identifiées (transversales)

- **Autonomie des modules NixOS (L2)** : les modules `dnf/` actuels supposent souvent un contexte global (`usr/config.yaml`, secrets sops, voisins réseau). Il faudra introduire un mode « standalone » et des fixtures pour qu'une machine puisse être instanciée seule dans le test driver.
- **`disko` non exercé par microvm.nix (L3)** : les microvm gèrent leurs propres disques d'overlay au build time, le `disko.nix` réel de chaque machine n'est pas testé en L3. C'est précisément le rôle de la catégorie de scénarios *install* en L2 (`nixos-anywhere --vm-test`).
- **Aspects non-déclaratifs (L3)** : certaines briques (headscale, peering tailscale, premiers logins, registration de tokens) ne sont pas encore 100 % déclaratives. Le lab L3 doit prévoir une couche de **hooks dynamiques** post-boot par scénario.
- **Cycle de vie des secrets de test** : la clé d'infra de test ne doit jamais fuiter dans le projet de production ; isolation stricte (`.gitignore`, répertoire dédié, jamais de référence depuis `usr/`).
- **Pont entre L2 et L3** : à terme, viser une définition de topologie commune (un même YAML décrit le scénario, consommé soit par le test driver soit par microvm.nix) — pas requis en v1.

## Choix repoussés (à trancher plus tard)

- **Tests tailscale/headscale mesh** : fidélité (tailscaled réel dans chaque VM) vs simplifié — à décider au moment de l'implémentation du module dédié
- **Déploiement validation post-staging** (colmena/deploy-rs) : hors périmètre staging strict ; à noter que `colmena` est déjà utilisé par `just apply`
- **Boucle de correction agentique** (proposition de patches Nix) : v2 après stabilisation des rapports
- **Parallélisation runs** : le test driver est monothreaded par défaut, à orchestrer plus tard si besoin
- **Migration `unit-tests` → `test`** : conserver l'ancienne recette comme alias ou faire un rename strict — à décider lors de l'implémentation
- **Suppression des scripts VBox** : conservés tant que le L3 n'est pas opérationnel

## Outils écartés et pourquoi

- **VirtualBox** (utilisé par les scripts actuels) : remplacé par QEMU/microvm.nix — meilleure intégration Nix, déclaratif, pas de dépendance binaire externe, support natif des VLANs virtuels
- **nixai** : ajoute une couche subprocess sans gain net face à un wrapper Python qui contrôle ses prompts et l'agrégation
- **CrewAI / LangGraph** : overkill pour un pipeline linéaire « collecte → agents spécialisés → rapport »
- **Firecracker / cloud-hypervisor** pour le lab persistant : exclus à cause des postes graphiques (GUI non supportée)
- **Terranix** : redondant avec une conf Nix multi-machines déjà existante

## Cartographie des fichiers (cible)

- `dnf/tests/unit/` — **conservé** (L1, tests unitaires existants)
- `dnf/tests/simulate/` — **nouveau** (L2, scénarios runtime NixOS Test Driver, exposés via `flake.nix#checks`, fixtures pour mode standalone)
- `dnf/tests/simulate/install/` — **nouveau** (L2, scénarios *install* basés sur `nixos-anywhere --vm-test`, un par machine cible)
- `dnf/tests/lab/` — **nouveau** (L3, modules microvm.nix + profils de lab + hooks dynamiques par scénario)
- `dnf/tests/lab/usr-test/` — **nouveau** (projet DNF parallèle à `usr/` : `config.yaml`, secrets de test, machines virtuelles)
- `dnf/tests/ai/` — **nouveau** (wrapper Python multi-provider, prompts, schémas pydantic des rapports)
- `dnf/tests/vms-*.sh` — **dépréciés** (à supprimer après bascule L3)
- `Justfile` — ajout des recettes `test <what>`, `simulate <what>` (familles *runtime* et *install*), `launch-lab <what>` (+ `stop-lab`, `purge-lab`, `lab-status`, `lab-test`, `lab-apply`) ; recette `unit-tests` réorganisée

## Références

- [NixOS Test Driver](https://nixos.org/manual/nixos/stable/#chap-developing-the-test-driver)
- [microvm.nix](https://github.com/astro/microvm.nix)
- [nix-unit](https://github.com/nix-community/nix-unit)
- [LiteLLM](https://docs.litellm.ai/)
- [pydantic-ai](https://ai.pydantic.dev/)
- [instructor](https://python.useinstructor.com/)
