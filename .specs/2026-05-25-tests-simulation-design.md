# Spec — Architecture des tests de simulation DNF

- **Date** : 2026-05-25
- **Périmètre** : `darkone-nixos-framework` (`/etc/nixos/dnf`)
- **Statut** : design validé en brainstorm, à transformer en plan d'implémentation
- **Objectif** : poser l'**architecture** et le **mécanisme** d'écriture/exécution des tests `testers` (`runNixOSTest`), autonome dans le repo framework (CI/CD), claire et évolutive.

---

## 1. Contexte

Pipeline DNF :

```
etc/config.yaml ──(dnf-generator, Rust)──▶ var/generated/{hosts,users,network,config}.nix
                                                    │
                                                    ▼
                  lib/mk-configuration.nix (mkConfigurations workDir)
                  lit var/generated/* + usr/* ──▶ colmena hive + nixosConfigurations + ISO
                                                    │
                                                    ▼
                  modules/ (darkone.*) consommant les specialArgs :
                  host, zone, network, hosts, users, userNixosProfiles,
                  workDir, dnfLib, pkgs-stable
```

Existant réutilisé :
- `tests/unit/` (`nix-unit`, `.#libTests`) — conservés, à étoffer.
- `darkone.test.standalone` (`modules/system/testing.nix`) — seam déjà consommé par `core.nix` et `ncps.nix`. **Rétréci** par cette spec.
- `just install <host> test` → `nixos-anywhere --flake .#<host> --vm-test` — base du tier L4.

---

## 2. Décisions validées

1. **Source de vérité de l'inventaire** : fixtures générées **commitées** + passage par le **vrai `mkConfigurations`**.
2. **L1 eval-only** : oui — force `config.system.build.toplevel` sans boot.
3. **Tests d'installation** : maintenant, via `nixos-anywhere --vm-test`.
4. **Réseau complet** : stub LAN multi-zones (VLANs du driver) ; VPN/TLS neutralisés.
5. **Secrets sops haute-fidélité** : sops **réel** dans les VM via fixtures pré-générées. Pureté : statique commité, **aucune génération à l'éval/run**.
6. **Trois workspaces génériques** : `node` / `network` / `vpn`.
7. **DRY sans IFD** : symlinks relatifs commités.
8. **Vocabulaire commun** `node`/`network`/`vpn` reliant `lib` ↔ `workspaces` ↔ `scenarios`.
9. **Refactor `mkNodes`** (jalon 0) : API publique `node = { modules, specialArgs, system }` (variante `forTest`), source de vérité unique.
10. **Transport** : **colmena conservé** ; interchangeable plus tard via `mkNodes`.

---

## 3. Vue d'ensemble — niveaux et axes

| Niveau | Helper | Boote des VM ? | Couvre |
|--------|--------|----------------|--------|
| L1 eval | `mkEvalTest` | non | `toplevel` de tous les hôtes |
| L2 node | `mkNodeTest` | 1 VM | machine (module/service/profil) |
| L3 network | `mkNetworkTest` | N VM + VLANs | LAN multi-machines, gw autonome |
| L3+ vpn | `mkVpnTest` | N VM + VLANs | zones, headscale (VPN stub) |
| L4 install | `mkInstallTest` | 1 VM | disko + `nixos-anywhere --vm-test` |

**Axe spatial** = `node` / `network` / `vpn`. **Modes orthogonaux** = `eval` (tout workspace) et `install` (node + disko).

---

## 4. Arborescence cible

```
tests/
├── unit/                                   # nix-unit sur lib/
├── fixtures/                               # PRÉ-GÉNÉRÉ, commun à tous les workspaces
│   ├── keys/test-infra.age
│   ├── secrets/{secrets.yaml,.sops.yaml}
│   └── tls/{cert.pem,key.pem}
├── lib/                                    # helpers
│   ├── workspace.nix                       #   workDir -> { ws, hosts, hostNames, nodeOf }
│   ├── test-tuning.nix                     #   seam ON, clé sops, taille VM
│   ├── mk{Eval,Node,Network,Vpn,Install}Test.nix  #   L1-L4
│   └── vlans.nix                           #   zone -> vlan
├── workspaces/                             # peu d'environnements, génériques
│   ├── _skeleton/usr/                      #   inerte, partagé
│   │     └── secrets -> ../../fixtures/secrets
│   ├── node/configs/<variant>/{etc/config.yaml,var/generated/,usr -> ../../../_skeleton/usr}
│   ├── network/configs/<variant>/...
│   └── vpn/configs/<variant>/...
└── scenarios/                              # tests courts, auto-découverts
    ├── default.nix                         # auto-découverte -> checks attrset
    ├── eval-all.nix
    ├── modules/   node-console-git.nix …
    ├── machines/  node-laptop.nix …
    ├── services/  node-server-immich.nix …
    ├── networks/  network-dns.nix  vpn-multizone.nix …
    └── installs/  node-disko-server-btrfs-luks.nix …
```

Correspondance de noms :

| Base | lib | workspace | préfixe scénario |
|------|-----|-----------|------------------|
| node | `mkNodeTest` | `workspaces/node` | `node-*.nix` |
| network | `mkNetworkTest` | `workspaces/network` | `network-*.nix` |
| vpn | `mkVpnTest` | `workspaces/vpn` | `vpn-*.nix` |

---

## 5. Workspaces

Un **workspace** = un `workDir` au sens de `mkConfigurations` : `etc/config.yaml`, `var/generated/*.nix`, `usr/`.

- Peu d'environnements : `node`, `network`, `vpn`. Sous chacun, `configs/<variant>/`.
- `_skeleton/usr/` : parties inertes mutualisées, chaque variant pointe dessus par symlink.
- `_skeleton/usr/secrets` → `fixtures/secrets` (symlink) — store sops partagé.
- Utilisateurs de test : jeu fixe minimal (`nix` + `darkone` en profil `minimal`).

### Pureté / DRY sans IFD

`workDir` reste un **répertoire source** du repo (pas de `symlinkJoin` → pas d'IFD). Mutualisation par **symlinks relatifs commités**.

---

## 6. Fixtures communes (pré-générées, commitées)

- `fixtures/keys/test-infra.age` : clé age **jetable**, nommée `INSECURE-test-only`, ne protège que des secrets de test.
- `fixtures/secrets/{secrets.yaml,.sops.yaml}` : store sops **commun** chiffré pour la clé ci-dessus.
- `fixtures/tls/{cert.pem,key.pem}` : cert auto-signé fixe (stub ACME).
- Régénération rare via `just fixtures gen-secrets`.

---

## 7. Seam de test — `darkone.test.standalone` (rétréci)

Le seam **ne masque plus sops**. Il neutralise uniquement l'irréductiblement externe/runtime :
- `services.headscale` → no-op
- `services.tailscale` → no-op
- ACME → bascule sur cert auto-signé (chemin fourni en option)

**Frontière framework ↔ test :**
- `modules/system/testing.nix` (**framework**) : déclare le toggle, neutralisations **comportementales** uniquement. **Ne référence aucun fichier de `tests/`**.
- `tests/lib/test-tuning.nix` (**test**) : active `standalone = true`, **injecte la clé sops de test**, fournit le cert auto-signé, dimensionne la VM.

sops fonctionne **pour de vrai** dans la VM (déchiffrement à l'activation).

---

## 8. Helpers `lib/` — contrats

### `workspace.nix`

```nix
# Charge un workspace, expose de quoi replug-er ses hôtes dans le test driver,
# SANS modifier mkConfigurations.
{ inputs }:
let mkConfigurations = import ../../lib/mk-configuration.nix { inherit inputs; };
in workDir:
let
  ws    = mkConfigurations workDir;
  hosts = import (workDir + "/var/generated/hosts.nix");
  nodes = ws.mkNodes { forTest = true; };   # API publique (cf. §9.1)
in {
  inherit ws nodes hosts;
  hostNames = builtins.attrNames nodes;
  nodeOf = name: nodes.${name};
}
```

### `mkEvalTest.nix` (L1)

```nix
{ pkgs, inputs }:
{ name, workspaces }:   # workspaces : liste de workDir
# Dérivation qui dépend de chaque
# (workspace).ws.nixosConfigurations.<host>.config.system.build.toplevel
# -> force l'éval+build de tous les hôtes, sans booter.
```

### `mkNodeTest.nix` (L2)

```nix
{ pkgs, inputs }:
{ name
, workspace          # ex. ../workspaces/node/configs/server-immich
, host               # hostname à éprouver
, testModule ? { }   # surcharges du scénario
, testScript         # script python du driver
}:
# -> pkgs.testers.runNixOSTest {
#      nodes.<host> = { imports = node.modules ++ [ ./test-tuning.nix testModule ]; };
#      node.specialArgs = node.specialArgs;
#      inherit name testScript;
#    }
```

### `mkNetworkTest.nix` (L3) / `mkVpnTest.nix` (L3+)

```nix
{ pkgs, inputs }:
{ name, workspace
, hosts ? null          # sous-ensemble (défaut: tous)
, testScript }:
# Pour chaque hôte : nodes.<h> = { imports = node.modules ++ [ test-tuning + vlans ]; }
# specialArgs PAR node (via _module.args) — cf. §9 risque (5).
# vpn : mêmes mécanismes + headscale stubbé.
```

### `mkInstallTest.nix` (L4)

```nix
{ pkgs, inputs }:
{ name, workspace, host }:
# config.yaml du workspace doit inclure un profil disko pour <host>.
# Réutilise nixos-anywhere --vm-test (cf. §11).
```

---

## 9. Source de vérité unique `mkNodes` + replug → `runNixOSTest`

### 9.1 Refactor `mkNodes` (framework — jalon 0)

`lib/mk-configuration.nix` mélange « inventaire → node » et « construction du `nixosSystem` final ». On extrait une **API publique unique** :

```nix
mkNodes = { forTest ? false }:
  # -> { <host> = { modules = [ … ]; specialArgs = { … }; system = "…"; }; }
```

Tous les consommateurs en dérivent :

```
mkNodes ──┬──▶ nixosConfigurations.<h> = nixosSystem (node h)
          ├──▶ colmena.<h>             = … node.modules …          (conservé)
          ├──▶ runNixOSTest nodes.<h>  = node.modules ++ [ test ]   (TESTS)
          └──▶ install                 = node.modules ++ disko      (nixos-anywhere)
```

`forTest` : n'importe pas `"${nixpkgs}/nixos/modules/misc/nixpkgs.nix"` et ne pose pas `nixpkgs.hostPlatform.system` — le test driver possède la couche `nixpkgs`/`system`. Tout le reste (sops, services, home-manager) reste **identique à la prod**.

### 9.2 Replug : consommer `mkNodes` dans `runNixOSTest`

```nix
nodes = (mkConfigurations workDir).mkNodes { forTest = true; };
# node = nodes.<host> = { modules; specialArgs; system; }
runNixOSTest {
  nodes.<host> = { imports = node.modules ++ [ ./test-tuning.nix testModule ]; };
}
```

### 9.3 Risques

**Résolus par conception :**
- **(1) propriété `nixpkgs`/`system`** — `forTest` résout le conflit.
- **(2) home-manager lourd** — utilisateurs en profil `minimal`.
- **(3) collisions de specialArgs** — test consomme un contrat documenté, pas les internes colmena.
- **(6) noms d'interfaces** — fixés à l'avance pour coïncider avec les VLANs du driver.

**Résiduels — à valider empiriquement :**
- **(4) Modules à effets (sops/disko).** sops exige `keyFile` présent (fourni par `test-tuning`). disko inerte hors install.
- **(5) specialArgs PAR node en multi-host.** Passage par `_module.args` → risque de récursion connu. Nos specialArgs étant des **valeurs pré-calculées**, ça devrait être sûr — **à valider au 1er scénario réseau**.
- **(7) Coût d'éval/build.** Acceptable en node ; coûteux en network/vpn. Mitigation : configs minimales + L1.

---

## 10. Mapping zone → VLAN / interfaces (`lib/vlans.nix`)

- Chaque zone → numéro de VLAN (`virtualisation.vlans`).
- Hôte simple → une interface sur le VLAN de sa zone.
- Gateway → plusieurs interfaces : VLAN LAN + VLAN WAN.
- Noms d'interfaces **déterminés à l'avance** dans le `config.yaml` de test pour coïncider avec ceux du driver (`eth1`, `eth2`...).

---

## 11. Tier install L4

- Réutilise `nixos-anywhere --flake .#<host> --vm-test` (disko non-interactif).
- Parties interactives contournées : mot de passe via sops de test, pas de `read -p`.
- Factorisation requise : extraire la logique de `configure-admin-host` (clés/sops, `.sops.yaml`, mot de passe) en lib **appelable non-interactivement** — sert à la fois `configure-admin-host` et `just fixtures gen-secrets`.
- Exposition CI : ajouter `nixos-anywhere` comme **flake input**, exposer son vm-test en `.#checks`.

---

## 12. Découverte des scénarios → `.#checks`

- `tests/scenarios/default.nix` **auto-découvre** récursivement les `*.nix` sous `scenarios/` (hors `default.nix`).
- **Nom du check** = chemin relatif `/` → `-`, sans `.nix` (ex. `services/node-server-immich`).
- `flake.nix#checks.<system>` importe `default.nix` avec `{ pkgs, inputs }`.
- Auto-découverte ⇒ ajouter un scénario = déposer un fichier.

---

## 13. Debug interactif

- `runNixOSTest` expose `.driverInteractive`. Recette `just simulate-debug <scenario>` :
  - `nix run .#checks.<system>.<scenario>.driverInteractive`
  - REPL : `start_all()` puis `<machine>.shell_interact()`.

---

## 14. Commandes `just`

```
[group('check')]
fixtures action:        # dispatch : generate | check | gen-secrets
_fixtures_generate:     # dnf-generator sur chaque workspace -> var/generated/ (commité)
_fixtures_check:        # régénère en tmp + diff (anti-dérive CI)
_fixtures_gen_secrets:  # (rare) régénère fixtures/keys + fixtures/secrets
```

Conservés : `just simulate [<name>]`, `just simulate-debug <name>`, `just unit-tests`.

---

## 15. Migration des tests `simulate/` actuels

- `tests/simulate/` → remplacés par `tests/{lib,workspaces,scenarios,fixtures}`.
- 3 scénarios actuels → scénarios `node` réécrits via `mkNodeTest` + `workspaces/node`.
- `flake.nix#checks` repointé de `./tests/simulate` vers `./tests/scenarios`.
- Scénarios n'utilisent plus `core.enable = false` mais le seam + sops réel.

---

## 16. Évolutivité (changement de schéma `config.yaml`)

- Source unique par variant : `etc/config.yaml`. `var/generated/` dérivé.
- Changement de schéma ⇒ mettre à jour les `config.yaml` + `just fixtures generate`.
- `just fixtures check` en CI détecte toute dérive.

---

## 17. Hors-scope (cette session)

- Bootstrap headscale + join tailscale réel (mesh) — seam prévu, non implémenté.
- TLS/ACME réel (stub par cert auto-signé).
- Couverture exhaustive des services/modules.

---

## 18. Jalons d'implémentation

0. **Refactor `mkNodes`** (framework) : extraire l'API `node = {modules, specialArgs, system}`, recâbler, non-régression.
1. **Valider le replug** sur 1 hôte minimal — confirmer (3) et (1).
2. **Fixtures communes** : clé, secrets, TLS ; `just fixtures gen-secrets`.
3. **Seam rétréci** + `test-tuning.nix` (sops réel, headscale/tailscale no-op).
4. **Workspace `node`** + skeleton + `just fixtures generate/check` ; migrer 3 scénarios.
5. **L1 `mkEvalTest`** + `eval-all.nix`.
6. **Auto-découverte** + repoint `flake.nix#checks` + `simulate-debug`.
7. **`mkNetworkTest`** + `vlans.nix` sur 2 hôtes — risque (5).
8. **`mkVpnTest`** (zones + headscale stubbé).
9. **L4 `mkInstallTest`** : input `nixos-anywhere`, disko, check CI.

---

## Annexe — invariants

- **`mkNodes` = source de vérité unique** : tous les consommateurs passent par l'API `node = {modules, specialArgs, system}`.
- **Frontière framework ↔ test** : `modules/` ne référence jamais `tests/`.
- **Pas d'IFD** dans `nix flake check` (workDir = source, symlinks commités).
- **Pureté** : aucune génération de clé/secret à l'éval ou au run.
- **Scripts systemd** : tout binaire en chemin de store (`${pkgs.x}/bin/…`).
