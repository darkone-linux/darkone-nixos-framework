# Projet Darkone NixOS

Point de départ minimal pour un déploiement NixOS bâti sur le
[Darkone NixOS Framework](https://github.com/darkone-linux/darkone-nixos-framework).

Ce projet fournit la structure attendue par le framework, un `etc/config.yaml`
abondamment commenté à remplir, et rien d'autre. Aucun hôte, aucun
utilisateur, aucun fichier généré — c'est à vous de tout déclarer.

## Structure

```
flake.nix           Flake consommatrice (délègue tout à dnf)
Justfile            Recettes (importe dnf/just/project.just)
etc/config.yaml     Source de vérité — éditez ce fichier en premier
usr/                Votre surcouche locale
  modules/          Modules NixOS propres à ce déploiement
  home/             Surcouche home-manager, profils utilisateurs perso
  users/<login>/    Personnalisations par utilisateur (un dossier par login)
  machines/<hôte>/  Fichiers par hôte : configuration.nix, install/, hardware/
  secrets/          Secrets SOPS et clé de déploiement (jamais à la main)
var/generated/      Sortie du générateur — à commiter, jamais à éditer
dnf/                Symlink vers le framework (créé par `nix run .#init`)
```

## Démarrage

### 1. Créer votre dépôt

```sh
nix flake new -t github:darkone-linux/darkone-nixos-framework mon-reseau
cd mon-reseau && git init && git add -A
```

Ou depuis le [template GitHub](https://github.com/darkone-linux/dnf-boilerplate)
(bouton *Use this template*). Tout ce qui suit se passe dans le dépôt.

### 2. Amorcer le framework

```sh
# Pose le lien dnf/ -> l'arbre du framework dans le store nix
nix run github:darkone-linux/darkone-nixos-framework#init

# Entre dans un shell exposant dnf-generator, colmena, sops, just, nixfmt…
nix develop github:darkone-linux/darkone-nixos-framework
```

`just --list` affiche désormais toutes les recettes du framework (groupes
`apply`, `check`, `dev`, `install`, `manage`).

> [!NOTE]
> Le lien `dnf/` est ce qui donne ses recettes à `just` et ses profils au
> générateur (il les résout sur le disque). Il est gitignoré. Dès que votre
> projet a son propre `flake.lock`, rafraîchissez-le avec `nix run .#init` :
> cette forme suit la révision que *votre* lock épingle, tooling et système
> construit ne divergent donc jamais.

### 3. Initialiser les secrets d'administration

```sh
just configure-admin-host
```

Idempotente : crée la clé de déploiement `nix`, les clés age, `.sops.yaml`, un
mot de passe par défaut et les secrets internes des services déclarés ; ne
recrée jamais ce qui existe. À relancer après chaque nouveau service, hôte ou
utilisateur.

> [!IMPORTANT]
> À lancer sur la machine d'administration, qui est un hôte DNF : les recettes
> d'administration tournent sous son compte de déploiement `nix`, et
> s'arrêtent avec un message explicite partout ailleurs.

### 4. Décrire le déploiement

Tout se déclare dans `etc/config.yaml` (réseau, zones, utilisateurs, hôtes).
Les commentaires décrivent chaque champ. Un premier poste tient en une zone,
un utilisateur et un hôte — tout hôte appartient à une zone (ou porte une
adresse publique `ipv4`) :

```yaml
zones:
  main:
    description: "Réseau principal"
    ipPrefix: "10.0"          # cette zone utilise 10.0.0.0/16

users:
  alice:
    uid: 1000
    name: "Alice"
    profile: "nix-admin"
    groups: ["global"]

hosts:
  - hostname: "poste"
    name: "Poste de l'administrateur"
    zone: "main:1.10"         # IP fixe 10.0.1.10 ("main" seul = DHCP)
    profile: "desktop"
    users: ["alice"]
    disko:
      profile: "btrfs-1-disk"
      devices:
        main: "/dev/nvme0n1"
```

Puis régénérer et vérifier :

```sh
just generate      # var/generated/*.nix, usr/users/<login>/, usr/machines/<hôte>/
just check-flake   # nix flake check
git add . && git commit -m "Premier hôte"
```

> [!IMPORTANT]
> Commitez avant de construire. Les flakes nix ne voient que les fichiers
> suivis par git : un `var/generated/hosts.nix` ou un `usr/machines/<hôte>/`
> non suivi fait échouer toutes les constructions.

### 5. Installer le premier hôte

```sh
just build-iso                 # ISO du framework, portant votre clé
# la graver, démarrer la machine dessus, noter son IP
just full-install poste        # installation + configuration + déploiement
```

`full-install` enchaîne `just install` (nixos-anywhere + disko),
`just configure` (extraction matérielle, envoi des clés) et
`just apply-verbose`. Chaque étape reste utilisable séparément en cas d'échec.

L'installation fige la disposition des disques et le `system.stateVersion` de
l'hôte dans `usr/machines/<hôte>/install/` (commité). Le bloc `disko:` de
`etc/config.yaml` n'a alors plus d'effet et peut être retiré.

### 6. Au quotidien

```sh
just apply <hôte>       # déployer un hôte (colmena)
just apply-local        # déployer la machine courante
just enter <hôte>       # ssh en tant qu'utilisateur de maintenance nix
just clean              # fix + check + generate + format, avant de commiter
just update-flake       # met à jour les inputs, puis : nix run .#init
```

## Version du framework

`flake.nix` épingle une release du framework (tag) ; le `flake.lock` commité
la fige avec son nixpkgs. Pour monter de version :

1. inscrire le nouveau tag dans `inputs.dnf.url` ;
2. `nix flake update dnf`, puis commiter `flake.lock`.

…ou essayer une release sans l'adopter :

```sh
nixos-rebuild switch --flake .#<hôte> \
  --override-input dnf github:darkone-linux/darkone-nixos-framework/<tag>
```

Relancez `nix run .#init` après tout changement de révision épinglée.

## Pour aller plus loin

- Documentation : [FR](https://darkone-linux.github.io/fr/) • [EN](https://darkone-linux.github.io/en/)
- Code du framework : <https://github.com/darkone-linux/darkone-nixos-framework>
- Déploiement de référence : <https://github.com/darkone-linux/dnf-example>
- Code du générateur : <https://github.com/darkone-linux/dnf-generator>
