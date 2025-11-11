# Darkone NixOS Framework

> [!NOTE]
> A [documentation](https://darkone-linux.github.io) is available.

Une infrastructure réseau déclarative complète&nbsp;:

- Structure cohérente et modulaire.
- Outils préconfigurés et fonctionnels.
- Organisation pensée pour la scalabilité.

## Fonctionnalités

- **Multi-hosts et multi-users**, déploiements avec [colmena](https://github.com/zhaofengli/colmena) et [just](https://github.com/casey/just).
- **Installation automatisée** avec [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) + [disko](https://github.com/nix-community/disko).
- **Profils de postes (hosts)** pour serveurs, conteneurs, noeuds réseau et machines de travail.
- **Profils d'utilisateurs (users)** proposant des profils [home manager](https://github.com/nix-community/home-manager) types pour de nombreux utilisateurs.
- **Modules complets** et 100% fonctionnels avec un simple `.enable = true`.
- **Modules "mixin"** qui activent et configurent plusieurs modules en même temps.
- **Architecture extensible**, scalable, cohérente, personnalisable.
- **Multi-réseaux**, possibilité de déclarer plusieurs réseaux en une configuration.
- **[Homepage](https://github.com/gethomepage/homepage) et reverse-proxy** [Caddy](https://github.com/caddyserver/caddy) automatiques en fonction des services activés.
- **Sécurisation fiable** avec [sops](https://github.com/Mic92/sops-nix).

## Organisation

A la racine :

- `dnf` -> modules, users, hosts (framework)
- `usr` -> Projet local (en écriture)
- `var` -> Fichiers générés et logs
- `src` -> Fichiers source du générateur
- `doc` -> Documentation du projet

La [structure complète est documentée ici](https://darkone-linux.github.io/doc/introduction/#structure).

> [!NOTE]
> Cette structure peut être clonée pour chaque configuration et les parties communes 
> synchronisées dans un dépôt "upstream" commun.

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

Un poste "administrateur pour ordinateur portable" complet déclaré dans `usr/config.yaml` :

```yaml
hosts:
  static:
    - hostname: "darkone-laptop"   # Nom du host
      name: "An admin laptop"      # Description du host
      profile: admin-laptop        # Profil du host -> fonctionnalités à installer
      users: [ "darkone", "john" ] # Utilisateurs à installer sur le host
      groups: [ "admin" ]          # Groupes d'utilisateurs à installer
```

- Il existe des profils de hosts pré-configurés dans `dnf/modules/nix/host`.
- Les utilisateurs liés au host sont déclarés via `users` et/ou `groups`.
- Utilisateurs et groupes peuvent être déclarés dans la configuration ou dans LDAP.

> [!NOTE]
> On peut créer un nouveau poste informatique avec nixos-anywhere + disko.
>
> ```sh
> # Création automatique du poste "darkone-laptop"
> just full-install darkone-laptop nixos 192.168.1.234
> 
> # Puis mise à jour du poste au fur et à mesure
> just apply darkone-laptop
> ```

## Commandes d'administration (justfile)

```shell
❯ just
Available recipes:
    [apply]
    apply on what='switch'                         # Apply configuration using colmena
    apply-force on what='switch'                   # Apply with build-on-target + force repl. unk profiles [alias: a]
    apply-local what='switch'                      # Apply the local host configuration [alias: al]
    apply-verbose on what='switch'                 # Apply force with verbose options [alias: av]

    [check]
    check                                          # Recursive deadnix on nix files
    check-flake                                    # Check the main flake
    check-statix                                   # Check with statix

    [dev]
    cat                                            # just clean + git amend + apply-local test
    clean                                          # format: fix + check + generate + format [alias: c]
    develop                                        # Launch a "nix develop" with zsh (dev env) [alias: d]
    fix                                            # Fix with statix
    format                                         # Recursive nixfmt on all nix files
    generate                                       # Update the nix generated files
    pull                                           # Pull common files from DNF repository
    push                                           # Push common files to DNF repository

    [install]
    build-iso arch="x86_64-linux"                  # Build DNF iso image
    configure host                                 # New host: ssh cp id, extr. hw, clean, commit, apply
    configure-admin-host                           # Framework installation on local machine (builder / admin)
    copy-hw host                                   # Extract hardware config from host
    copy-id host                                   # Copy pub key to the node (nix user must exists)
    format-dnf-on host dev                         # Format and install DNF on an usb key (deprecated)
    format-dnf-shell                               # Nix shell with tools to create usb keys (deprecated)
    full-install host user='nix' ip='auto'         # New host: full installation (install, configure, apply)
    install host user='nix' ip='auto' do='install' # New host: format with nixos-everywhere + disko
    passwd user                                    # Update a user password
    passwd-default                                 # Update the default DNF password
    push-key host                                  # Push the infrastructure key to the host

    [manage]
    enter host                                     # Interactive shell to the host [alias: e]
    fix-boot on                                    # Multi-reinstall bootloader (using colmena)
    fix-zsh on                                     # Remove zshrc bkp to avoid error when replacing zshrc
    gc on                                          # Multi garbage collector (using colmena)
    halt on                                        # Multi-alt (using colmena)
    reboot on                                      # Multi-reboot (using colmena)

```

## A faire (todo)

### En cours

- [ ] [Nextcloud](https://wiki.nixos.org/wiki/Nextcloud) + configuration multi-postes.
- [ ] Services distribués (aujourd'hui les services réseau sont sur la passerelle).
- [ ] Stratégie de synchronisation avec syncthing.
- [ ] SSO avec [Authelia](https://github.com/authelia/authelia) ([module nix](https://search.nixos.org/options?channel=unstable&query=services.authelia))
  - Intégration du module Authelia (cf. mes notes, fichier `PAM`).
  - Gestion auto `secrets/users_database.yml` de authelia (via module ?).
  - Conf auto pour nginx, immich, nextcloud...
- [ ] Réseau distribué avec [Headscale](https://github.com/juanfont/headscale) + [WireGuard](https://www.wireguard.com/)
- [ ] Serveurs et postes "externes" (administrable mais ne faisant pas partie du LAN).
- [ ] Configuration pour réseau extérieur (https, dns, vpn...).
- [ ] Partages Samba pour windows + linux.

### Planifié (prioritaire)

- [ ] Let's encrypt
- [ ] Stratégie de sauvegarde, plusieurs options :
  - Ecosystème [Borg](https://github.com/borgbackup/borg) + [Borgmatic](https://github.com/borgmatic-collective/borgmatic) + [BorgWeb](https://github.com/borgbackup/borgweb) (plus maintenu ?) + [BorgWarehouse](https://github.com/ravinou/borgwarehouse) (bien mais pas intégré à nix) + [Vorta](https://vorta.borgbase.com/).
  - Ecosystème [Restic](https://github.com/kopia/kopia), bon module nix, plus simple, plus "CLI", plus de connexions que Borg, moins performant.
  - [Kopia](https://github.com/kopia/kopia) : très prometteur mais pas encore de module officiel pour NixOS.

### Planifié (secondaire)

- [ ] Intégration de [nixvim](https://nix-community.github.io/nixvim/).
- [ ] Gestion du secure boot avec [lanzaboote](https://github.com/nix-community/lanzaboote).
- [ ] Commandes d'introspection pour lister les hosts, users, modules activés par host, etc.
- [ ] Attributions d'emails automatiques par réseaux.
- [ ] Serveur de mails.
- [ ] Générateur / gestionnaire d'UIDs (pour les grands réseaux).
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
- [x] Gestion des mots de passe avec [sops](https://github.com/Mic92/sops-nix).
- [x] Passerelle : ajouter [adguard home](https://wiki.nixos.org/wiki/Adguard_Home).
- [x] just clean: détecter les fails, les afficher et s'arrêter.
- [x] Générer les stateVersion des users.
- [x] FQDN
- [x] Optimisations réseau :
  - Domaines locaux des machines -> 127.0.0.1 (shunt dnsmasq + adguard)
  - Homepage GW -> accès aux services globaux installés sur le réseau hors GW

### En pause

- [ ] Création de noeuds avec [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) + [disko](https://github.com/nix-community/disko).
- [ ] Gestion centralisée des utilisateurs avec [lldap](https://github.com/lldap/lldap).

## Remarques complémentaires

> [!WARNING]
> Après de nombreuses heures d'utilisation, il apparaît que Colmena et Deploy-rs ne répondent pas
> à une gestion de postes NixOS à large échelle. Je vais remplacer la configuration colmena actuelle
> par un équivalent non-nix, certainement [salt](https://github.com/saltstack/salt), pour administrer de nombreux postes en parallèle.
> Enfin, je ferai également en sorte de pouvoir builder et switcher chaque poste indépendemment au
> besoin, plutôt qu'être tributaire de la machine maître.
>
> ![Archi prévisionnelle avec Salt](doc/src/assets/new-network-architecture-black-tr.png)
