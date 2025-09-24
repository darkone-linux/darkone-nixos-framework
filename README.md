# Darkone NixOS Framework

Une configuration NixOS multi-utilisateur, multi-host.

> [!WARNING]
> Après de nombreuses heures d'utilisation, il apparaît que Colmena et Deploy-rs ne répondent pas
> à une gestion de postes NixOS à large échelle. Je vais remplacer la configuration colmena actuelle
> par un équivalent non-nix, certainement [salt](https://github.com/saltstack/salt), pour administrer de nombreux postes en parallèle.
> Enfin, je ferai également en sorte de pouvoir builder et switcher chaque poste indépendemment au
> besoin, plutôt qu'être tributaire de la machine maître.
>
> ![Archi prévisionnelle avec Salt](doc/src/assets/new-network-architecture-black-tr.png)

> [!NOTE]
> A [documentation](https://darkone-linux.github.io) is available.

Ce framework simplifie la gestion d'une infra réseau grâce à&nbsp;:

- Une structure cohérente et modulaire.
- Des outils préconfigurés et fonctionnels.
- Une organisation pensée pour la scalabilité.

## Fonctionnalités

Fonctionnel :

- **Multi-hosts et multi-users**, déploiements avec [colmena](https://github.com/zhaofengli/colmena) et [just](https://github.com/casey/just).
- **Profils de hosts** pour serveurs, conteneurs et machines de travail.
- **Profils de users** proposant des confs types pour de nombreux utilisateurs.
- **Modules complets** et 100% fonctionnels avec un simple `.enable = true`.
- **Modules "macro"** qui activent et configurent plusieurs modules en même temps.
- **Architecture extensible**, scalable, cohérente, personnalisable.
- **Gestion des paramètres** utilisateur avec [home manager](https://github.com/nix-community/home-manager) + profils de homes.
- **Configuration transversale** pour assurer la cohérence du réseau.
- **Multi-réseaux**, possibilité de déclarer plusieurs réseaux en une configuration.

A venir :

- **[Homepage](https://github.com/gethomepage/homepage) automatique** en fonction des services activés.
- **Sécurisation facile et fiable**, un seul mdp pour déverrouiller, avec [sops](https://github.com/Mic92/sops-nix).

## Organisation

A la racine :

- `dnf` -> modules, users, hosts (framework)
- `usr` -> Projet local (en écriture)
- `var` -> Fichiers générés et logs
- `src` -> Fichiers source du générateur
- `doc` -> Documentation du projet

La [structure complète est documentée ici](https://darkone-linux.github.io/doc/introduction/#structure).

> [!NOTE]
> Cette structure peut être clonée pour chaque configuration et les parties communes synchronisées dans un dépôt "upstream" commun.

## Le générateur

```shell
# Lancer le générateur
just generate

# Génération + formattages + checks
just clean
```

![Darkone NixOS Framework Generator](doc/src/assets/arch.webp)

Son rôle est de générer une configuration statique pure à partir d'une définition de machines (hosts), utilisateurs et groupes en provenance de diverses sources (déclarations statiques, ldap, etc. configurées dans `usr/config.yaml`). La configuration nix générée est intégrée au dépôt afin d'être fixée et utilisée par le flake.

## Exemples

Un poste bureautique complet :

```nix
# usr/modules/nix/host/admin-laptop.nix
{ lib, config, ... }:
let
  cfg = config.darkone.host.admin-laptop;
in
{
  options = {
    darkone.host.admin-laptop.enable = lib.mkEnableOption "An admin laptop";
  };

  config = lib.mkIf cfg.enable {

    # Darkone modules
    darkone = {

      # Based on laptop framework profile
      host.laptop.enable = true;

      # Advanced user (developper / admin)
      theme.advanced.enable = true;

      # Nix administration features
      admin.nix.enable = true;
    };

    # Host specific state version
    system.stateVersion = "25.05";
  };
}
```

On déclare des machines correspondantes dans `usr/config.yaml` :

```yaml
hosts:
    static:
        - hostname: "darkone-laptop"
          name: "A PC"
          profile: admin-laptop
          users: [ "darkone", "john" ]
```

- Il existe aussi des profils de hosts pré-configurés dans `dnf/modules/nix/host`.
- Les utilisateurs liés au host sont déclarés via `users` et/ou `groups`.
- Utilisateurs et groupes peuvent être déclarés dans la configuration ou dans LDAP.

> [!NOTE]
> On peut créer un nouveau poste informatique depuis l'iso d'installation.
>
> ```sh
> # Création de l'iso d'installation
> nix build .#start-img-iso
> ```
>
> Création du poste et mises à jour :
>
> ```sh
> # Mettre à jour la passerelle pour enregistrer le poste sur le DNS
> just apply gateway
>
> # Echange les clés, récupère la conf hardware, génère la conf et applique
> just install pc01
>
> # On peut ensuite mettre à jour à tout moment
> just apply pc01
> ```

### Créer une passerelle complète

Elle contient un serveur DHCP + DNS auto-configurés avec tous les postes déclarés dans la conf.

```yaml
# usr/config.yaml
network:
  domain: "arthur.lan"
  locale: "fr_FR.UTF-8"
  timezone: "America/Miquelon"
  gateway:
    hostname: "gateway" # required (if a gateway exists)
    wan:
      interface: "enp1s0" # required
    lan:
      interfaces: ["enp2s0", "wlo1", "wlp0s20f0u1"] # required
      ip: "192.168.1.1"
      prefixLength: 24
      dhcp-range:
        - "192.168.1.200,192.168.1.230,24h"

hosts:
    static:
        - hostname: "gateway"
          name: "Local Gateway"
          profile: local-gateway
          groups: [ "nix-admin" ]
```

Déploiement :

```sh
just apply gateway
```

## Justfile

```shell
❯ just
Available recipes:
    [apply]
    apply on what='switch'       # Apply configuration using colmena
    apply-force on what='switch' # Apply with build-on-target + force repl. unk profiles
    apply-local what='switch'    # Apply the local host configuration

    [check]
    check                        # Recursive deadnix on nix files
    check-flake                  # Check the main flake
    check-statix                 # Check with statix

    [dev]
    clean                        # format: fix + check + generate + format
    develop                      # Launch a "nix develop" with zsh (dev env)
    fix                          # Fix with statix
    format                       # Recursive nixfmt on all nix files
    generate                     # Update the nix generated files
    pull                         # Pull common files from DNF repository
    push                         # Push common files to DNF repository

    [install]
    copy-hw host                 # Extract hardware config from host
    copy-id host                 # Copy pub key to the node (nix user must exists)
    format-dnf-on host dev       # Format and install DNF on an usb key (danger)
    format-dnf-shell             # Nix shell with tools to create usb keys
    install host                 # New host: ssh cp id, extr. hw, clean, commit, apply
    install-local                # Framework installation on local machine (builder)

    [manage]
    enter host                   # Interactive shell to the host
    fix-boot on                  # Multi-reinstall bootloader (using colmena)
    fix-zsh on                   # Remove zshrc bkp to avoid error when replacing zshrc
    gc on                        # Multi garbage collector (using colmena)
    halt on                      # Multi-alt (using colmena)
    reboot on                    # Multi-reboot (using colmena)
```

## A faire (todo)

### En cours

- [ ] Gestion des mots de passe avec [sops](https://github.com/Mic92/sops-nix).
- [ ] Gestion centralisée des utilisateurs avec [lldap](https://github.com/lldap/lldap).
- [ ] [Nextcloud](https://wiki.nixos.org/wiki/Nextcloud) + synchronisation des home directories.
- [ ] Passerelle : ajouter [adguard home](https://wiki.nixos.org/wiki/Adguard_Home).

### Planifié

- [ ] Configuration pour réseau extérieur (https, dns, vpn...)
- [ ] Services distribués (aujourd'hui les services réseau sont sur la passerelle)
- [ ] Intégration de [nixvim](https://nix-community.github.io/nixvim/).
- [ ] Gestion du secure boot avec [lanzaboote](https://github.com/nix-community/lanzaboote).
- [ ] Commandes d'introspection pour lister les hosts, users, modules activés par host, etc.
- [ ] Attributions d'emails automatiques par réseaux.
- [ ] Serveur de mails.
- [ ] Générateur / gestionnaire d'UIDs (pour les grands réseaux).
- [ ] just clean: détecter les fails, les afficher et s'arrêter.
- [ ] Réseau social à voir : [mattermost](https://search.nixos.org/options?channel=unstable&from=0&size=50&sort=relevance&type=packages&query=services.mattermost), [mastodon](https://search.nixos.org/options?channel=unstable&from=0&size=50&sort=relevance&type=packages&query=services.mastodon), [matrix](https://nixos.wiki/wiki/Matrix), [gotosocial](https://search.nixos.org/options?channel=24.11&from=0&size=50&sort=relevance&type=packages&query=services.gotosocial), [zulip](https://zulip.com/self-hosting/)...

### Fait

- [x] Architecture modulaire.
- [x] Configuration colmena.
- [x] Configuration transversale générale.
- [x] Déploiements avec Just (build regular + apply colmena).
- [x] Générateur de configuration nix statique.
- [x] Modules système de base (hardware, i18n, doc, network, performances).
- [x] Modules console de base (zsh, git, shell).
- [x] Modules graphic de base (gnome, jeux de paquetages).
- [x] Hosts préconfigurés : minimal, serveur, desktop, laptop.
- [x] [Justfile](https://github.com/casey/just) pour checker et fixer les sources.
- [x] Postes types (bureautique, développeur, administrateur, enfant).
- [x] Builder d'[ISOs d'installation](https://github.com/nix-community/nixos-generators) pour les machines à intégrer.
- [x] Multi-réseaux.
- [x] Fixer les UIDs (des users).
- [x] Normaliser les données générées en séparant hosts et users.
- [x] Configuration multi-architecture (x86_64 & aarch64).
- [x] Passerelle type (dhcp, dns, ap, firewall, adguard, AD, VPN).
- [x] Documentation FR et EN.
- [x] [Nix Cache Proxy Server](https://github.com/kalbasit/ncps).
- [x] Homepage automatique en fonction des services activés.
- [x] Générateur automatique de documentation à partir des sources.
- [x] Sécurisation avec [fail2ban](https://github.com/fail2ban/fail2ban) ([module](https://search.nixos.org/options?channel=unstable&from=0&size=50&sort=relevance&type=packages&query=services.fail2ban)).

### En pause

- [ ] Création de noeuds avec [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) + [disko](https://github.com/nix-community/disko).

## Idées en cours d'étude

> [!CAUTION]
> Pas encore fonctionnel.

### Installation K8S préconfigurée

Master (déclaration qui fonctionne sans autre configuration) :

```nix
{
  # Host k8s-master
  darkone.k8s.master = {
    enable = true;
    modules = {
      nextcloud.enable = true;
      forgejo.enable = true;
    };
  };
}
```

Slave (connu et autorisé par master car déclaré dans la même conf nix) :

```nix
{
  # Host k8s-slave-01
  darkone.k8s.slave = {
    enable = true;
    master.hostname = "k8s-master";
  };
}
```

Master avec options :

```nix
{
  # Host k8s-master
  darkone.k8s.master = {
    enable = true;
    modules = {
      nextcloud.enable = true;
      forgejo.enable = true;
    };
    preemtibleSlaves = {
      hosts = [ "k8s-node-01" "k8s-node-02" ];
      xen.hypervisors = [
        {
          dom0 = "xenserver-01";
          vmTemplate = "k8s-node";
          minStatic = 3;
          maxPreemptible = 20;
        }
      ];
    };
  };
}
```

### Commandes d'introspection

```shell
# Host list with resume for each
just host

# Host details : settings, activated modules, user list...
just host my-pc

# User list with resume (name, mail, host count)
just user

# User details : content, feature list, host list...
just user darkone
```
