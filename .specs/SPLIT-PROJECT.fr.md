# Découpage du monorepo DNF en projets séparés

> Document de référence pour la séparation du repo `/etc/nixos` en plusieurs
> repos indépendants. À lire **avant** toute extraction.

## Objectif

Le repo monolithique mélange aujourd'hui plusieurs préoccupations indépendantes.
On veut les publier séparément pour :

- **Isoler les cycles de release** : le framework évolue indépendamment des déploiements.
- **Permettre l'adoption par des tiers** via un boilerplate clonable (projet réel ou privé qui utilise le framework).
- **Distribuer le générateur** comme outil réutilisable hors DNF.
- **Héberger la doc** sans tirer le framework complet.
- **Itérer en parallèle** sur le framework et un déploiement réel.

Note : "projet réel" désignera le projet privé ou le boilerplate à partir duquel on construit un projet privé.

---

## Repos cibles

| Repo                          | Source actuelle        | Type             | Visibilité  |
|-------------------------------|------------------------|------------------|-------------|
| `darkone-nixos-framework`     | `dnf/`                 | Flake Nix (lib)  | public      |
| `dnf-generator`               | `src/generator/`       | Crate Rust       | public      |
| `dnf-doc`                     | `doc/`                 | Astro/Starlight  | public      |
| `dnf-boilerplate`             | `/` sans doc, dnf, src | Flake Nix (app)  | public      |
| *(projet privé)*              | `/` (dont `/usr`)      | Flake Nix (app)  | privé       |

**Point important** : le répertoire `/etc/nixos` **est déjà** le projet réel privé
`arthur-network` (son `.git` actuel est celui d'arthur-network). Sur lui repose un
développement mutualisé de tous les projets. Le framework, en revanche, n'a pas
encore de `.git` propre : il sera créé par extraction depuis un clone du repo
courant, puis posé manuellement dans `/etc/nixos/dnf/.git`.

L'organisation des dossiers et fichiers ne change quasiment pas :

- `/` Contient un projet réel (privé). On génèrera un boilerplate à partir de ce projet.
- `/usr` et `/var` font partie du projet réel (privé).
- `/src/generator` sera un projet Crate Rust indépendant. Le projet réel se bindera sur ce projet si ses sources sont présentes dans `/src/generator`.
- `/doc` sera un projet starlight indépendant, qui accèdera aux sources du framework via `../dnf` (comme d'habitude, via générateur).
- `/flake.nix` sera scindé, le framework aura son propre flake (`/dnf/flake.nix`), le projet réel sera bindé sur le framework.

---

## Analyse du couplage actuel

| De → Vers                       | Couplage                                                 | Conséquence                                  |
|---------------------------------|----------------------------------------------------------|----------------------------------------------|
| `dnf/` → `usr/`                 | **Aucun**                                                | Framework déjà pur, extraction propre        |
| `usr/` → `dnf/`                 | Imports relatifs dans `flake.nix` racine (L.149-150)     | À paramétrer via flake input                 |
| `flake.nix` → `var/generated/`  | `hosts.nix`, `users.nix`, `network.nix` (L.104-106)      | Reste côté consommateur (boilerplate/privé)  |
| `src/generator` → racine        | Lit `etc/config.yaml`, écrit `var/generated/` (CWD)      | A utiliser à la racine du projet             |
| `Justfile` racine               | Orchestre les 4 (generate, format, check, switch)        | Reste dans arthur-network ; framework garde un Justfile minimal |
| `doc/` → reste                  | **Aucun**                                                | Détachement trivial                          |

Aucune dépendance circulaire. La séparation se fait par couches.

---

## Fiche — `dnf-generator`

- **Contenu** : `src/generator/` (crate Cargo `dnf-generator`).
- **Modifs requises** :
  1. Flag `--workdir <path>` (défaut = CWD) pour localiser `etc/config.yaml`
     et écrire `var/generated/`. Aucune référence en dur à `dnf/` ou `usr/`.
  2. **Adapter les sources** : le chemin du fichier de config admin passe de
     `usr/config.yaml` à `etc/config.yaml` (intégrer le nouveau défaut dans
     le code du générateur).
  3. `flake.nix` exposant `packages.default = dnf-generator`.
  4. Sous-commande `doc` : génère la doc Starlight dans `--out <path>` (défaut
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
  structure éditoriale (intro, guides, tutos) sauf quelques fichiers `ref/*`
  qui seraient écrasés par la CI.
- **Modifs requises** : workflow CI de build/déploiement (Pages/Vercel/CF) +
  réception du contenu auto-généré (push manuel).
- **Risque** : nul.

---

## Fiche — `darkone-nixos-framework` (repo actuel)

- **Contenu** : `dnf/*` + `flake.nix` exposant :
  - `nixosModules`, `homeManagerModules`
  - `lib` (= `dnfLib` actuel) + `lib.mkConfigurations` (nouveau helper)
- **Modifs requises** :
  1. Extraction de la logique d'assemblage de `flake.nix` racine (L.113-152)
     vers **`dnf/lib/mkConfigurations.nix`** — fonction `{ workDir, inputs } →
     { nixosConfigurations, homeConfigurations, ... }`. Seul point d'entrée
     pour les consommateurs.
  2. Création de `dnf/flake.nix` (framework standalone) qui expose
     `lib.mkConfigurations`, `nixosModules`, `homeManagerModules` et un
     devShell minimal pour `just unit-tests` / `nix flake check`.
  3. Le framework **épingle** le générateur via son input (cf. « Versioning »).
  4. Création du `.git` framework par extraction depuis un clone séparé de
     `/etc/nixos` (cf. « Commandes utiles »). Le clone subit un `git mv`
     pour remonter `dnf/*` à la racine, suivi d'un `git rm` des fichiers
     hors framework. Le `.git` ainsi produit est ensuite déposé manuellement
     dans `/etc/nixos/dnf/.git`. Les SHA antérieurs sont préservés (les
     renames sont détectés par git → `git log --follow` reste fonctionnel).
  5. Déplacer `README.md`, `README.fr.md` et `TODO.fr.md` (intégralement)
     vers `dnf/` lors de la restructuration.
  6. Scinder `AGENTS.md` : règles framework → `dnf/AGENTS.md` ; règles projet
     privé (arthur-network) → `AGENTS.md` racine.
  7. **CI doc autogénérée** : workflow GitHub Actions sur tag (`v*`) qui
     exécute `dnf-generator doc --out /tmp/ref` puis ouvre une PR contre
     `dnf-doc` remplaçant le contenu de `src/content/ref/`. dnf-doc reste
     maître éditorial sur le reste.
  8. **Tests** : inchangés. CI `.github/workflows/unit-tests.yml` autonome.
- **Note** : les sources du framework seront développées au travers d'un projet
  réel (arthur-network). On doit pouvoir cependant exécuter les tests unitaires
  de manière autonome (sans projet réel) et les laisser intégrées au CI GitHub.
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

## Fiche — projet réel (`arthur-network`)

- **Identité** : `/etc/nixos` lui-même. Son `.git` actuel **est** déjà celui
  d'`arthur-network` (privé, hébergé sur le GitHub du mainteneur). Pas de
  réinitialisation, pas de migration.
- **Contenu après split** :
  - `flake.nix` : flake du projet privé (consommateur).
  - `etc/config.yaml` : configuration admin (ex-`usr/config.yaml`).
  - `usr/`, `var/generated/` : modules custom, machines, users, home,
    sorties du générateur (commitées).
  - `dnf/` : repo framework cloné côte-à-côte (co-développement par défaut).
  - `src/generator/` : repo générateur cloné côte-à-côte (co-dev).
  - `doc/` : repo `dnf-doc` cloné côte-à-côte (co-dev).
- **`flake.nix` (mode co-dev par défaut)** :

  ```nix
  inputs.dnf.url = "path:./dnf";
  inputs.dnf-generator.url = "path:./src/generator";
  inputs.nixpkgs.follows = "dnf/nixpkgs";

  outputs = inputs: inputs.dnf.lib.mkConfigurations {
    workDir = ./.;
    inherit inputs;
  };
  ```

- **Bascule mode release** : commuter `inputs.dnf.url` vers
  `github:darkone-linux/darkone-nixos-framework/<tag>` et idem pour le
  générateur (`dnf-generator.follows = "dnf/dnf-generator"` redevient
  pertinent). Le `flake.lock` se met à jour, on commit.
- **Risque** : moyen — c'est le test d'intégration grandeur nature.

---

## Fiche — `dnf-boilerplate`

- **Contenu** : à construire à partir du projet réel `arthur-network` (**plus tard**).
- **Note** : `boilerplate` est plus parlant que `template`. En revanche, `dnf-boilerplate` est bien un template github (La feature GitHub « template repository » s'active indépendamment du nom.).
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

## Versioning : framework épingle le générateur

**Deux modes coexistent** selon le type de consommateur :

- *Co-dev* (par défaut sur `arthur-network`) : `inputs.dnf.url = "path:./dnf"`,
  idem pour le générateur. Toute modif locale est prise en compte
  immédiatement, pas d'épinglage versionné, le `flake.lock` suit les hash
  des paths.
- *Release* (boilerplate + consommateurs tiers) : `inputs.dnf.url =
  "github:.../v1.2.0"` + `dnf-generator.follows = "dnf/dnf-generator"`. C'est
  ce mode que décrit le pattern `follows` ci-dessous.

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

Co-développement **par défaut** sur `arthur-network` : son `flake.nix` racine
référence `path:./dnf` et `path:./src/generator`. Toute modif dans ces
sous-arbres est instantanément visible au `nixos-rebuild switch`. Pas de
trick `--override-input`, pas de `flake.nix.local`.

### Cas particuliers

**1. Tester arthur-network contre une release figée du framework** :

```bash
sudo nixos-rebuild switch --flake .#myhost \
  --override-input dnf github:darkone-linux/darkone-nixos-framework/v1.2.0
```

**2. Tester le framework seul (sans projet réel)** :

```bash
cd /etc/nixos/dnf
nix flake check          # checks framework standalone
just unit-tests          # tests unitaires Nix
```

**3. Boilerplate ou consommateur tiers en co-dev ponctuel** :

```bash
cd ~/code/my-boilerplate-clone
nix build .#nixosConfigurations.myhost.config.system.build.toplevel \
  --override-input dnf path:/etc/nixos/dnf
```

Le boilerplate (mode release par défaut) accepte un override-input ponctuel
pour pointer sur un clone local du framework, sans modifier son `flake.nix`.

---

## Ordre d'exécution recommandé

Le `/etc/nixos/.git` courant restera celui d'arthur-network — il ne bouge pas.
On extrait depuis lui les trois repos publics, puis on réorganise sur place.

1. **Extraire `dnf-doc`** depuis un clone séparé (cf. « Commandes utiles ») :
   `git filter-repo --path doc/ --path-rename doc/:`. Push vers
   `darkone-linux/dnf-doc`.

2. **Extraire `dnf-generator`** depuis un clone séparé :
   `git filter-repo --path src/generator/ --path-rename src/generator/:`.
   Adapter le crate : flag `--workdir`, défaut de config admin
   (`etc/config.yaml`), sous-commande `doc`. Push vers
   `darkone-linux/dnf-generator`.

3. **Extraire `darkone-nixos-framework`** depuis un clone séparé. Procédure
   détaillée dans « Commandes utiles » :
   - `git mv dnf/* .` (et descendre les `dnf/README*`, `dnf/AGENTS.md`,
     etc. à la racine du clone).
   - `git rm -rf doc/ src/ usr/ var/` et fichiers racine non-framework.
   - Création de `flake.nix` framework (à partir de l'ancien `dnf/flake.nix`
     si déjà créé, ou ex nihilo) exposant `lib.mkConfigurations`.
   - Création de `lib/mkConfigurations.nix` (extraction depuis l'ancien
     `flake.nix` racine, L.113-152).
   - Commit unique « restructure: framework standalone ».
   - Push vers `darkone-linux/darkone-nixos-framework`, tag `v0.1.0`.

4. **Déposer le `.git` framework dans `/etc/nixos/dnf/`** (manuel) :
   - Avant : `/etc/nixos/dnf/` est encore un sous-dossier tracké par
     arthur-network.
   - Action : déplacer `.git` du clone framework vers `/etc/nixos/dnf/.git`.
   - Vérifier `cd /etc/nixos/dnf && git status` ; commiter les diffs
     résiduels s'il y en a.

5. **Adapter `/etc/nixos` (arthur-network) au nouveau monde** :
   - Renommer `usr/config.yaml` → `etc/config.yaml` (intégrer aussi dans le
     code du générateur).
   - Réécrire `/etc/nixos/flake.nix` en consommateur (mode co-dev par défaut,
     `inputs.dnf.url = "path:./dnf"`).
   - Ajouter `.gitignore` : ignorer `dnf/`, `src/generator/`, `doc/`
     (devenus des sous-repos cibles à part). `var/generated/` reste committé.
   - Scinder `AGENTS.md` (règles framework déjà parties dans `dnf/`).
   - Commit le tout dans `/etc/nixos/.git` (= arthur-network).

6. **Mettre en place le workflow CI doc** (framework → dnf-doc) sur tag.

7. **Créer `dnf-boilerplate`** à partir d'arthur-network (plus tard) :
   - Repo neuf, pas d'historique privé.
   - Mode release par défaut (URLs github + tags).
   - Activer la feature GitHub « template repository ».

Pendant 1-3, la machine reste pleinement fonctionnelle (les builds courants
pointent sur l'état déployé, indépendant du repo). Le point de non-retour est
l'étape 4 : une fois `dnf/.git` posé, retirer `dnf/*` du tracking
arthur-network engage le projet définitivement.

---

## Points à trancher

- [x] **Namespace GitHub** : `darkone-linux/*`.
- [x] **Versioning** : framework épingle le générateur via input, consommateurs
      utilisent `follows`. SemVer indépendant.
- [x] **Doc autogénérée** : CI dans `darkone-nixos-framework` à chaque tag,
      push (ou PR) vers `dnf-doc/src/content/ref/`.
- [x] **Historique git** : le `/etc/nixos/.git` courant reste celui
      d'arthur-network. Les trois repos publics (framework, doc, générateur)
      sont extraits depuis des clones séparés via `git filter-repo` (doc,
      générateur) ou `git mv` + `git rm` (framework). `dnf-boilerplate` est
      créé ex nihilo (historique vierge).
- [x] **Projet privé** : `/etc/nixos` lui-même = `arthur-network`,
      consommateur au même titre que le boilerplate, mais en mode co-dev
      par défaut (path-based).
- [x] **Tests d'intégration** : portés par le framework ; le schéma de
      `etc/config.yaml` est le contrat partagé entre framework, boilerplate
      et arthur-network. Emplacement exact dans le framework à arbitrer
      lors de la restructuration.
- [x] **Dev en parallèle** : co-dev path-based **par défaut** sur
      arthur-network ; `--override-input` réservé aux cas particuliers
      (boilerplate ponctuel, test contre une release).
- [x] **`var/generated/` dans boilerplate** : gitignored (regénéré à chaque
      clone, oblige à avoir `dnf-generator` installé) ou commité (build
      possible sans Rust) ? -> Commité et généré avec dnf-generator. Le générateur est une dépendance indispensable du projet.
- [x] **Tests d'intégration cross-repo** : workflow nightly dans le boilerplate
      qui tire la HEAD du framework et lance `nix flake check` (canari) ? -> le framework contiendra un scénario qui utilise le boilerplate pour tester ses modules (plus tard).

---

## Fichiers critiques pendant l'exécution

- `/etc/nixos/flake.nix` (L.104-106, L.113-124, L.149-150) — sera scindé :
  partie consommateur reste à la racine (arthur-network), partie framework
  est extraite vers `/etc/nixos/dnf/flake.nix` (à créer dans le clone
  framework).
- `/etc/nixos/Justfile` — reste dans arthur-network. Le framework aura son
  propre Justfile minimal (tests unitaires, `nix flake check`).
- `/etc/nixos/src/generator/AGENTS.md` — spec des sous-commandes du
  générateur ; voyage avec le crate dans le nouveau repo.
- `/etc/nixos/usr/config.yaml` → `/etc/nixos/etc/config.yaml` : renommage,
  défaut à intégrer dans le code du générateur.
- `/etc/nixos/var/generated/` — contrat de sortie du générateur (schéma) ;
  commité dans arthur-network et dans le boilerplate.
- `/etc/nixos/dnf/lib/mkConfigurations.nix` — à créer dans le clone
  framework (extraction de la logique d'assemblage du `flake.nix` racine).
- `/etc/nixos/dnf/flake.nix` — à créer dans le clone framework.

---

## Commandes utiles (appendice)

Toutes les extractions se font sur des **clones séparés** de `/etc/nixos`.
Le `/etc/nixos/.git` courant (= arthur-network) ne bouge pas.

### 1. Extraction de `dnf-doc`

```bash
nix-shell -p git-filter-repo

git clone --no-local /etc/nixos /tmp/dnf-doc
cd /tmp/dnf-doc
git filter-repo --path doc/ --path-rename doc/:
git remote remove origin
git remote add origin git@github.com:darkone-linux/dnf-doc.git
git push -u origin main
```

### 2. Extraction de `dnf-generator`

```bash
git clone --no-local /etc/nixos /tmp/dnf-generator
cd /tmp/dnf-generator
git filter-repo --path src/generator/ --path-rename src/generator/:
# Adapter le crate : flag --workdir, défaut etc/config.yaml, sous-commande doc
git remote remove origin
git remote add origin git@github.com:darkone-linux/dnf-generator.git
git push -u origin main
```

### 3. Extraction de `darkone-nixos-framework`

Préparation dans un clone séparé : on remonte `dnf/*` à la racine, on retire
tout ce qui n'est pas du framework, on ajoute le `flake.nix` standalone.

```bash
git clone --no-local /etc/nixos /tmp/dnf-framework
cd /tmp/dnf-framework
rm -rf .git
sudo cp -r /home/darkone/dnf/.git .
sudo chown -R nix .git

# a. Remonter le contenu de dnf/ à la racine
git mv dnf/lib lib
git mv dnf/modules modules
git mv dnf/home home
git mv dnf/tests tests
git mv dnf/hosts hosts
git mv dnf/dotfiles dotfiles
git mv dnf/assets assets
# (lister tous les sous-dossiers de dnf/ ici si d'autres existent)

# b. Retirer ce qui part dans d'autres repos ou reste côté arthur-network
git rm -rf doc/ src/ usr/ var/
git rm -f flake.nix flake.lock Justfile opencode.json
git rm -f AGENTS.md CLAUDE.md
#   (les README et TODO racine sont restent en place, on créera de nouveaux README pour les autres projets.)

# c. Créer ou descendre les fichiers framework à la racine :
#    - flake.nix : framework standalone, expose lib.mkConfigurations
#    - lib/mkConfigurations.nix : extraction de /etc/nixos/flake.nix L.113-152
#    - Justfile minimal : unit-tests, check
#    - AGENTS.md à supprimer (pour le moment on laisse dans arthur-network)
#    - TODO.fr.md, README.md, README.fr.md framework (récupéré depuis arthur-network)

# d. Commit unique
git add -A
git commit -m "Restructure: framework standalone (dnf/ → root)"

# e. Push + tag
git remote remove origin
git remote add origin git@github.com:darkone-linux/darkone-nixos-framework.git
git push -u origin main
git tag v0.1.0 && git push --tags

# f. on remet dans /etc/nixos
cd /etc/nixos
rm -rf dnf
echo "dnf/" > .gitignore
mv /tmp/dnf-framework /etc/nixos/dnf
```

À ce stade, `/etc/nixos/dnf/` est un repo `darkone-nixos-framework`
fonctionnel, et `/etc/nixos/.git` (arthur-network) voit les nouveau `dnf/*`.

### 5. Mode co-dev (mode par défaut d'arthur-network)

```bash
cd /etc/nixos
sudo nixos-rebuild switch --flake .#myhost
# → pioche directement dans ./dnf et ./src/generator (path-based)
```

### 6. Bascule en mode release (test ponctuel)

```bash
sudo nixos-rebuild switch --flake .#myhost \
  --override-input dnf github:darkone-linux/darkone-nixos-framework/v0.1.0
```

### 7. Vérification post-séparation

```bash
# dnf-doc :
cd /tmp/dnf-doc && npm install && npm run build

# dnf-generator :
cd /tmp/dnf-generator && cargo test
./target/debug/dnf-generator --workdir /tmp/fixture hosts

# framework standalone :
cd /etc/nixos/dnf && nix flake check

# arthur-network :
cd /etc/nixos && nix build .#nixosConfigurations.<host>.config.system.build.toplevel
```

### Check-list de validation finale

- [ ] `dnf-doc` : `npm run build` réussit, site déployé.
- [ ] `dnf-generator` : `cargo test`, `dnf-generator --workdir /tmp/test hosts`
      produit un `var/generated/hosts.nix` valide.
- [ ] `darkone-nixos-framework` : `nix flake check` autonome passe.
- [ ] CI doc : un tag sur le framework pousse bien vers `dnf-doc/src/content/ref/`.
- [ ] `arthur-network` : `nixos-rebuild switch` OK en mode co-dev.
- [ ] `arthur-network` : bascule release via `--override-input` OK.
- [ ] `dnf-boilerplate` (plus tard) : clone, `just generate`, `nix build` du host de démo.
