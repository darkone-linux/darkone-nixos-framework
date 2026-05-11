# Découpage du monorepo DNF en projets séparés

> Document de référence pour la séparation du repo `/etc/nixos` en plusieurs
> repos indépendants. À lire **avant** toute extraction.

## Objectif

Le repo monolithique mélange aujourd'hui plusieurs préoccupations indépendantes.
On veut les publier séparément pour :

- **Isoler les cycles de release** : le framework évolue indépendamment des déploiements.
- **Permettre l'adoption par des tiers** via un boilerplate clonable.
- **Distribuer le générateur** comme outil réutilisable hors DNF.
- **Héberger la doc** sans tirer le framework complet.
- **Itérer en parallèle** sur le framework et un déploiement réel.

---

## Repos cibles

| Repo                          | Source actuelle      | Type             | Visibilité  |
|-------------------------------|----------------------|------------------|-------------|
| `darkone-nixos-framework`     | **repo actuel**      | Flake Nix (lib)  | public      |
| `dnf-generator`               | `src/generator/`     | Crate Rust       | public      |
| `dnf-doc`                     | `doc/`               | Astro/Starlight  | public      |
| `dnf-boilerplate`             | dérivé de `usr/`     | Flake Nix (app)  | public      |
| *(projet privé)*              | `usr/`               | Flake Nix (app)  | privé       |

**Point important** : le repo actuel `/etc/nixos` **devient** le framework
(historique préservé). Les 3 autres repos publics sont extraits via
`git filter-repo`. Le déploiement actuel (ex-`usr/`) est sorti en **repo privé**
séparé — il devient un consommateur du framework au même titre que le
boilerplate.

---

## Analyse du couplage actuel

| De → Vers                       | Couplage                                                 | Conséquence                                  |
|---------------------------------|----------------------------------------------------------|----------------------------------------------|
| `dnf/` → `usr/`                 | **Aucun**                                                | Framework déjà pur, extraction propre        |
| `usr/` → `dnf/`                 | Imports relatifs dans `flake.nix` racine (L.149-150)     | À paramétrer via flake input                 |
| `flake.nix` → `var/generated/`  | `hosts.nix`, `users.nix`, `network.nix` (L.104-106)      | Reste côté consommateur (boilerplate/privé)  |
| `src/generator` → racine        | Lit `usr/config.yaml`, écrit `var/generated/` (CWD)      | Quasi-paramétrable, à confirmer              |
| `Justfile` racine               | Orchestre les 4 (generate, format, check, switch)        | À éclater ou déplacer vers boilerplate       |
| `doc/` → reste                  | **Aucun**                                                | Détachement trivial                          |

Aucune dépendance circulaire. La séparation se fait par couches.

---

## Fiche — `dnf-generator`

- **Contenu** : `src/generator/` (crate Cargo `dnf-generator`).
- **Modifs requises** :
  1. Flag `--workdir <path>` (défaut = CWD) pour localiser `usr/config.yaml` et
     écrire `var/generated/`. Aucune référence en dur à `dnf/` ou `usr/`.
  2. `flake.nix` exposant `packages.default = dnf-generator`.
  3. Sous-commande `doc` : génère la doc Starlight dans `--out <path>` (défaut
     = `./doc/`) ; sera consommée par le framework.
- **Tests** : `src/generator/tests/` voyage avec.
- **Distribution** : `cargo install --path .` + flake Nix.
- **Risque** : faible.

---

## Fiche — `dnf-doc`

- **Contenu** : `doc/` tel quel.
- **Statut actuel** : déjà autonome (package.json, astro.config.mjs, Justfile).
- **Particularité** : `src/content/ref/` est **autogénéré** par le générateur
  (voir « doc autogénérée » plus bas). Le repo `dnf-doc` reste maître de la
  structure éditoriale (intro, guides, tutos) saur quelques fichiers `ref/*` 
  qui seraient écrasés par la CI.
- **Modifs requises** : workflow CI de build/déploiement (Pages/Vercel/CF) +
  réception du contenu auto-généré (push manuel).
- **Risque** : nul.

---

## Fiche — `darkone-nixos-framework` (repo actuel)

- **Contenu** : `dnf/` remonté à la racine + `flake.nix` exposant :
  - `nixosModules`, `homeManagerModules`
  - `lib` (= `dnfLib` actuel) + `lib.mkConfigurations` (nouveau helper)
- **Modifs requises** :
  1. Suppression de `doc/`, `src/`, `usr/` **après** extraction.
  2. Contenu de `dnf/` remonté à la racine (cf. arbo UNIX plus bas).
  3. Extraction de la logique d'assemblage de `flake.nix` racine (L.113-152)
     vers **`lib/mkConfigurations.nix`** — fonction `{ workDir, inputs } →
     { nixosConfigurations, homeConfigurations, ... }`. Seul point d'entrée
     pour les consommateurs.
  4. Le framework **épingle** le générateur via son input (cf. « Versioning »).
  5. Sortie doc auto-générée poussée vers `dnf-doc/src/content/ref/` (CI).
  6. **Tests d'intégration** : `tst/integration/` contient un mini-projet
     fixture (un host, un user, un `config.yaml`) dont le schéma est **le
     contrat partagé** avec le boilerplate.
- **Risque** : moyen — refactor de la couche d'assemblage Nix.

### Esquisse `lib/mkConfigurations.nix`

```nix
{ lib, inputs }:
{ workDir, extraSpecialArgs ? {} }:
let
  hosts   = import (workDir + "/var/generated/hosts.nix");
  users   = import (workDir + "/var/generated/users.nix");
  network = import (workDir + "/var/generated/network.nix");
in {
  nixosConfigurations = lib.mapAttrs (name: host:
    inputs.nixpkgs.lib.nixosSystem {
      # … logique actuellement dans /etc/nixos/flake.nix
    }
  ) hosts;
  # idem homeConfigurations
}
```

---

## Fiche — `dnf-boilerplate`

- **Contenu** : structure minimale dérivée de `usr/`, prête à cloner.
- **Note** : `boilerplate` est plus parlant que `template` (qui en plus a un
  sens GitHub spécifique). La feature GitHub « template repository » s'active
  indépendamment du nom — `dnf-boilerplate` peut être marqué comme template.
- **`flake.nix` type** :

  ```nix
  {
    inputs.dnf.url = "github:darkone-linux/darkone-nixos-framework";
    # Le générateur suit la version épinglée par le framework :
    inputs.dnf-generator.follows = "dnf/dnf-generator";
    inputs.nixpkgs.follows = "dnf/nixpkgs";

    outputs = inputs: inputs.dnf.lib.mkConfigurations {
      workDir = ./.;
      inherit inputs;
    };
  }
  ```

- **Usage** : « Use this template » → clone → édite `etc/config.yaml` →
  `just generate && just switch`.
- **Risque** : moyen — c'est le test d'intégration grandeur nature.

---

## Arborescence UNIX-style (proposition)

Préférence : répertoires courts type UNIX à la racine. Pragmatisme : les
conventions Nix (`modules/`, `home/`) sont fortes, mais on peut s'aligner sur
l'esprit `/etc /usr /var /lib`.

### Framework (`darkone-nixos-framework`)

```text
darkone-nixos-framework/
├── lib/       # helpers Nix (dnfLib, mkConfigurations)
├── modules/   # modules NixOS (ex-dnf/modules)
├── home/      # home-manager modules (ex-dnf/home)
├── tests/     # tests unit + intégration (ex-dnf/tests)
├── etc/       # fixtures de démo (host minimal pour nix flake check)
├── doc/       # accès direct à la doc (dnf-doc)
├── src/       # accès direct aux sources de projets tiers (générateur...)
├── var/       # artefacts générés par les tests (gitignored)
├── flake.nix
├── Justfile
├── AGENTS.md
└── README.md
```

### Boilerplate (`dnf-boilerplate`) et projet privé

Arbo UNIX :

```text
dnf-boilerplate/
├── etc/                  # configs admin
│   ├── config.yaml       # ex-usr/config.yaml
│   └── secrets/          # clés SOPS
├── usr/                  # contenu utilisateur
│   ├── machines/
│   ├── users/
│   ├── modules/          # modules NixOS custom
│   └── home/             # home-manager custom
├── var/                  # généré par dnf-generator
│   └── generated/        # hosts.nix, users.nix, network.nix
├── dnf/                  # accès direct aux sources du framework
├── flake.nix
├── Justfile
└── README.md
```

---

## Versioning : framework épingle le générateur

Pattern `follows` Nix standard, identique à `nixpkgs.follows` :

**Côté framework** (`darkone-nixos-framework/flake.nix`) :

```nix
inputs.dnf-generator.url = "github:darkone-linux/dnf-generator/v0.5.2";
```

**Côté consommateur** (boilerplate + projet privé) :

```nix
inputs.dnf.url = "github:darkone-linux/darkone-nixos-framework/v1.2.0";
inputs.dnf-generator.follows = "dnf/dnf-generator";  # hérite mécaniquement
```

**Conséquence** : pinner une version du framework induit la version du
générateur. Une seule décision d'upgrade pour le consommateur. Le framework
reste maître de la compatibilité (`var/generated/*.nix` schema ↔ générateur).

**SemVer indépendant** sur framework et générateur, **mais** chaque release du
framework déclare quelle version du générateur elle requiert.

---

## Dev en parallèle (framework + projet réel)

Cas typique : tu modifies le framework ET ton déploiement privé en même temps,
et tu veux builder le projet privé avec le framework local non commité.

### Trois patterns, du plus léger au plus durable

**1. `--override-input` à la volée (recommandé pour test ponctuel)** :

```bash
cd ~/code/my-private-deployment
nix build .#nixosConfigurations.myhost.config.system.build.toplevel \
  --override-input dnf path:/home/me/code/darkone-nixos-framework
```

Idem pour `nixos-rebuild` :

```bash
sudo nixos-rebuild switch --flake .#myhost \
  --override-input dnf path:/home/me/code/darkone-nixos-framework
```

Aucun fichier à modifier, aucune trace dans git.

**2. Override durable via `flake.nix` local (recommandé pour session de dev)** :

Créer `flake.nix.local` (gitignored) ou simplement éditer temporairement
`flake.nix` :

```nix
# Décommenter pour dev local :
# inputs.dnf.url = "path:/home/me/code/darkone-nixos-framework";
```

Le `flake.lock` se met à jour, mais on **ne le commit pas** pendant la session
de dev. Au retour sur la version pinnée : `nix flake update dnf`.

**3. Recipe Justfile dédiée** :

```just
# Build avec framework local
build-local host:
  nix build .#nixosConfigurations.{{host}}.config.system.build.toplevel \
    --override-input dnf path:../darkone-nixos-framework
```

Tous les contributeurs ont la même commande sans modifier le flake.

### Bonus : `direnv` + `flake.nix.local`

Pour une isolation totale, un `.envrc` peut exporter une variable consommée par
un wrapper Justfile. Mais c'est probablement overkill : `--override-input`
suffit dans 99 % des cas.

---

## Ordre d'exécution recommandé

1. **`dnf-doc`** — extraction triviale, valide le workflow `git filter-repo`.
2. **`dnf-generator`** — ajouter `--workdir`, publier, vérifier sur le monorepo.
3. **`darkone-nixos-framework`** (= refonte du repo actuel) :
   - extraire `mkConfigurations` vers `lib/`
   - remonter `dnf/*` à la racine
   - épingler `dnf-generator`
   - mettre en place la CI doc auto-générée vers `dnf-doc`
   - tagger `v0.1.0`
4. **`dnf-boilerplate`** — créer ex nihilo (pas d'historique à préserver),
   tester sur une VM. Activer la feature GitHub « template repository ».
5. **Migration du projet privé** : extraire `usr/` actuel en repo privé,
   adapter au nouveau pattern (`inputs.dnf.url = …`). Premier consommateur réel.
6. **Nettoyage du repo framework** : supprimer `doc/`, `src/generator/`, `usr/`.

Pendant toutes les étapes 1-5, le monorepo `/etc/nixos` reste fonctionnel.
L'étape 6 est le point de non-retour.

---

## Points à trancher

- [x] **Namespace GitHub** : `darkone-linux/*`.
- [x] **Versioning** : framework épingle le générateur via input, consommateurs
      utilisent `follows`. SemVer indépendant.
- [x] **Doc autogénérée** : CI dans `darkone-nixos-framework` à chaque tag,
      push (ou PR) vers `dnf-doc/src/content/ref/`.
- [x] **Historique git** : préservé pour le framework (repo actuel) ; extraits
      via `git filter-repo` pour `dnf-doc` et `dnf-generator` ; vierge pour
      `dnf-boilerplate`.
- [x] **Projet privé** : repo séparé, consommateur au même titre que le
      boilerplate.
- [x] **Tests d'intégration** : dans le framework (`tst/integration/`),
      schéma `config.yaml` = contrat partagé avec le boilerplate.
- [x] **Dev en parallèle** : `--override-input` + recipe Justfile dédiée.
- [ ] **Arbo framework** : Option A (UNIX-strict 3-char) vs Option B
      (conventionnel Nix) — à valider.
- [ ] **`var/generated/` dans boilerplate** : gitignored (regénéré à chaque
      clone, oblige à avoir `dnf-generator` installé) ou commité (build
      possible sans Rust) ? À valider.
- [ ] **Tests d'intégration cross-repo** : workflow nightly dans le boilerplate
      qui tire la HEAD du framework et lance `nix flake check` (canari) ?

---

## Fichiers critiques pendant l'exécution

- `/etc/nixos/flake.nix` (L.104-106, L.113-124, L.149-150) — imports à extraire.
- `/etc/nixos/Justfile` (L.147-177, L.244-316) — orchestration à éclater.
- `/etc/nixos/src/generator/AGENTS.md` — spec des sous-commandes du générateur.
- `/etc/nixos/var/generated/` — contrat de sortie du générateur (schéma).
- `/etc/nixos/dnf/lib/` — futur emplacement de `mkConfigurations.nix`.

---

## Commandes utiles (appendice)

### Extraction d'un sous-dossier (préserve l'historique)

```bash
nix-shell -p git-filter-repo

# Pour dnf-doc :
git clone --no-local /etc/nixos /tmp/dnf-doc
cd /tmp/dnf-doc
git filter-repo --path doc/ --path-rename doc/:
git remote add origin git@github.com:darkone-linux/dnf-doc.git
git push -u origin main

# Idem pour dnf-generator (remplacer doc/ par src/generator/).
```

### Refonte du repo framework (sur place)

```bash
cd /etc/nixos
# 1. Remonter dnf/* à la racine (selon arbo choisie)
git mv dnf/lib lib
git mv dnf/modules mod   # ou modules/
git mv dnf/home hm       # ou home/
git mv dnf/tests tst     # ou tests/
# 2. Supprimer ce qui part dans d'autres repos
git rm -r doc/ src/generator/ usr/
# 3. Adapter flake.nix, Justfile, AGENTS.md
# 4. Tagger
git tag v0.1.0
```

### Dev en parallèle

```bash
# Build du projet privé avec framework local :
cd ~/code/my-private-deployment
nix build .#nixosConfigurations.myhost.config.system.build.toplevel \
  --override-input dnf path:/home/me/code/darkone-nixos-framework

# nixos-rebuild avec override :
sudo nixos-rebuild switch --flake .#myhost \
  --override-input dnf path:/home/me/code/darkone-nixos-framework
```

### Vérification post-séparation

```bash
# dnf-doc
cd /tmp/dnf-doc && npm install && npm run build

# dnf-generator
cd /tmp/dnf-generator && cargo test
./target/debug/dnf-generator --workdir /tmp/fixture hosts

# darkone-nixos-framework
nix flake check  # avec host de démo dans etc/ (ou examples/)

# dnf-boilerplate (intégration finale)
git clone https://github.com/darkone-linux/dnf-boilerplate /tmp/mynix
cd /tmp/mynix && just generate
nix build .#nixosConfigurations.<host>.config.system.build.toplevel
```

### Check-list de validation finale

- [ ] `dnf-doc` : `npm run build` réussit, site déployé.
- [ ] `dnf-generator` : `cargo test`, `dnf-generator --workdir /tmp/test hosts`
      produit un `var/generated/hosts.nix` valide.
- [ ] `darkone-nixos-framework` : `nix flake check` passe sur le host fixture.
- [ ] CI doc : un tag sur le framework push bien vers `dnf-doc/src/content/ref/`.
- [ ] `dnf-boilerplate` : clone, `just generate`, `nix build` du host de démo.
- [ ] **Projet privé** : migration réussie, `nixos-rebuild switch` OK.
- [ ] Dev en parallèle : `--override-input` fonctionne sur les deux côtés.
