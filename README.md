# Darkone NixOS Framework

Une configuration NixOS multi-utilisateur, multi-host, multi-réseaux.

> [!NOTE]
> A [documentation](https://darkone-linux.github.io) is available.

> [!WARNING]  
> Projet en cours de développement.

Ce framework simplifie les choses grâce à&nbsp;:

- Une structure cohérente et modulaire.
- Des outils préconfigurés et fonctionnels.
- Une organisation pensée pour la scalabilité.

## Fonctionnalités

- **Multi-hosts et multi-users**, déploiements avec [colmena](https://github.com/zhaofengli/colmena) et [just](https://github.com/casey/just).
- **Profils de hosts** pour serveurs, conteneurs et machines de travail.
- **Profils de users** proposant des confs types pour de nombreux utilisateurs.
- **Modules complets** et 100% fonctionnels avec un simple `.enable = true`.
- **Architecture extensible**, scalable, cohérente, personnalisable.
- **Gestion des paramètres** utilisateur avec [home manager](https://github.com/nix-community/home-manager) + profils de homes.
- **[Homepage](https://github.com/gethomepage/homepage) automatique** en fonction des services activés.
- **Configuration transversale** pour assurer la cohérence du réseau.
- **Sécurisation facile et fiable**, un seul mdp pour déverrouiller, avec [sops](https://github.com/Mic92/sops-nix).
- **Multi-réseaux**, possibilité de déclarer plusieurs réseaux en une configuration.

## Organisation

A la racine :

- `lib` -> modules, users, hosts (framework)
- `usr` -> Projet local (en écriture)
- `var` -> Fichiers générés et logs
- `src` -> Fichiers source du générateur
- `doc` -> Documentation du projet

```
flake.nix .................... Main flake
Justfile ..................... Project management
lib/ ......................... Projet library (framework)
├── modules/ ................. Framework modules
│   ├── default.nix .......... Auto-generated default (by Justfile)
│   ├── system/(...) ......... System / Hardware configurations
│   │   ├── core.nix
│   │   ├── i18n.nix
│   │   └── doc.nix
│   ├── console/(...) ........ CLI applications
│   ├── graphic/(...) ........ X applications
│   ├── service/(...) ........ Daemons
│   ├── admin/(...) .......... Nix administration settings
│   │   └── nix.nix .......... Nix tools
│   ├── user/ ................ User management (not home)
│   │   ├── nix.nix .......... Nix special user (for deployments)
│   │   └── build.nix ........ Users builder
│   ├── host/ ................ Host profiles (macro-modules)
│   │   ├── desktop.nix
│   │   ├── laptop.nix
│   │   ├── server.nix
│   │   ├── vm.nix
│   │   └── minimal.nix
│   └── theme/ ............... Thematic features (macro-modules)
│       ├── office.nix
│       ├── advanced.nix
│       └── student.nix
└── homes/ ................... User profiles configuration (.nix) + home profiles (dirs)
    ├── admin.nix ............ Admin user profile configuration (extragroups, etc.)
    ├── admin/(...) .......... Admin user profile home
    ├── advanced(...) ........ Advanced user with development tools
    ├── minimal(...) ......... Easy environment
    ├── normal(...) .......... Non-technical user
    ├── gamer(...) ........... Optimized environment for gamers
    └── child(...) ........... Kids softwares and settings
usr/ ......................... Writable zone for local network project
├── modules/(...) ............ Local modules
├── secrets/(...) ............ Local secrets file
├── homes/(...) .............. Home profiles
├── machines/(...) ........... Machine specific configuration by hostname
├── hosts/(...) .............. Host profiles
└── config.yaml .............. Local configuration used by the generator
var/
├── log/
└── generated/ ............... Generated files
    ├── hosts.nix ............ Hosts to deploy
    └── networks.nix ......... Networks configuration
src/(...) .................... Generator sources
```

> [!NOTE]
> Pour le moment il est prévu que le framework soit cloné et que le projet de l'utilisateur soit situé dans `usr`, qui peut recevoir un projet git indépendant. Avoir une séparation entre le projet local et le framework (qui serait un simple input du flake local) est en cours d'étude.

## Le générateur

```shell
# Utilisation
just generate

# Génération + formattages + checks
just clean
```

![Darkone NixOS Framework Generator](doc/src/assets/arch.webp)

Son rôle est de générer une configuration statique pure à partir d'une définition de machines (hosts), utilisateurs et groupes en provenance de diverses sources (déclarations statiques, ldap, etc. configurées dans `usr/config.yaml`). La configuration nix générée est intégrée au dépôt afin d'être fixée et utilisée par le flake.

## Exemples

> [!CAUTION]
> Ces exemples ne sont pas encore complement fonctionnels et pourront différer dans la future version stable du projet.

Configurer un template de poste bureautique complet se fait très simplement :

```nix
# usr/hosts/desktop-office.nix
{
  # Activate all the necessary to have an office PC
  darkone.host.desktop.enable = true;

  # Activate the "office" theme with related softwares
  darkone.theme.office.enable = true;

  # Add obsidian to the previous configuration
  darkone.graphic.obsidian.enable = true;
}
```

Puis on déclare des machines dans la configuration `usr/config.yaml` :

```yaml
hosts:
    static:
        - hostname: "my-pc"
          name: "A PC"
          profile: desktop-office
          users: [ "darkone" "john" ]
```

- Le profile `desktop-office` fait référence à `usr/modules/host/desktop-office.nix`.
- Il existe aussi des profils de hosts pré-configurés dans `lib/modules/host`.
- Les utilisateurs liés au host sont déclarés via `users` et/ou `groups`.
- Utilisateurs et groupes peuvent être déclarés dans la configuration ou dans LDAP.

> [!NOTE]
> Pour créer un poste, le plus simple est d'installer l'iso d'initialisation.
>
> ```sh
> # Création de l'iso d'installation
> nix build .#start-img-iso
> ```
> 
> Création du poste et mises à jour (commandes simplifiées et optimisées) :
>
> ```sh
> # Création du host "pc01"
> just apply pc01 <ip-du-poste>
> 
> # Mise à jour
> just apply pc01
> 
> # Mise à jour de tous les "desktop"
> just apply @desktop
> ```
>
> On peut aussi utiliser des commandes régulières :
> 
> ```sh
> # Injection de la conf de patrick dans un poste physique
> # sur lequel a été installé l'iso du framework
> nixos-anywhere --flake '.#patrick' --target-host nix@<ip-du-poste>
> 
> # Mise à jour
> colmena apply --on patrick switch
> 
> # Mise à jour de tous les desktops
> colmena apply --on @desktop switch
> ```

### Créer une passerelle complète

Version minimale :

```nix
# usr/modules/host/server-gateway.nix

{ lib, config, ... }:
let
  cfg = config.darkone.host.server-gateway;
in
{
  options = {
    darkone.host.server-gateway.enable = lib.mkEnableOption "My gateway host profile";
  };

  config = lib.mkIf cfg.enable {
    darkone.host.gateway = {
      enable = true;
      wan.interface = "eth0";
      lan.interfaces = [ "eth1" "eth2" ];
    };
  };
}
```

Version plus complète :

```nix
# usr/modules/host/server-gateway.nix
# ...
darkone.host.gateway = {
  enable = true;
  wan = {
    interface = "eth0";
    gateway = "192.168.0.1"; # optional
  };
  lan = {
    interfaces = [ "wlan0" "enu1u4" ]; # wlan must be an AP
    bridgeIp = "192.168.1.1";
    domain = "arthur.lan"; # optional (default is <hostname>.lan)
    dhcp = { # optional
      enable = true;
      range = "192.168.1.100,192.168.1.230,24h";
      hosts = [
        "e8:ff:1e:d0:44:82,192.168.1.2,darkone,infinite"
        "f0:1f:af:13:62:a5,192.168.1.3,laptop,infinite"
      ];
      extraOptions = [
        "option:ntp-server,191.168.1.1"
      ];
    };
    accessPoints = [
      {
        wlan0 = {
          ssid = "Mon AP";
          passphrase = "Un password";
        };
      }
    ];
  };
};
# ...
```

Déploiement (2 possibilités) :

```sh
# Simple and optimal
just apply gateway

# Colmena
colmena apply --on gateway switch
```

## Justfile

```shell
❯ just
Available recipes:
    [_main]
    clean            # format (nixfmt) + generate + check (deadnix)
    install          # Framework installation (wip)

    [check]
    check            # Recursive deadnix on nix files
    check-flake      # Check the main flake
    check-statix     # Check with statix

    [touch]
    fix              # Fix with statix
    format           # Recursive nixfmt on all nix files
    generate         # Update the nix generated files

    [utils]
    ssh-copy-id host # Copy local id on a new node (wip)
```

## Liste TODO

### In progress

- [ ] Création de noeuds avec [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) + [disko](https://github.com/nix-community/disko) (wip).
- [ ] Homepage automatique en fonction des services activés (wip).
- [ ] Chaîne CI / CD pour la gestion de ce développement (wip).
- [ ] Tests unitaires (wip).
- [ ] Documentation FR et EN (wip).

### TODO

- [ ] Déploiements avec Just (build regular + apply colmena).
- [ ] Passerelle type (dhcp, dns, ap, firewall, adguard, AD, VPN).
- [ ] Services pré-configurés pour serveurs (nextcloud, etc.).
- [ ] Gestion centralisée des utilisateurs avec [lldap](https://github.com/lldap/lldap).
- [ ] Refactoring des commentaires de code en anglais.
- [ ] Intégration de [nixvim](https://nix-community.github.io/nixvim/).
- [ ] Gestion du secure boot avec [lanzaboote](https://github.com/nix-community/lanzaboote).
- [ ] Commandes d'introspection pour lister les hosts, users, modules activés par host, etc.
- [ ] Attributions d'emails automatiques par réseaux.
- [ ] Serveur de mails.
- [ ] Générateur / gestionnaire d'UIDs (pour les grands réseaux).
- [ ] Générateur automatique de documentation à partir des sources.
- [ ] just clean: détecter les fails, les afficher et s'arrêter.

### DONE

- [x] Architecture modulaire.
- [x] Configuration colmena.
- [x] Configuration transversale générale.
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

## Idées en cours d'étude

> [!CAUTION]
> Pas encore fonctionnel.

### Installation K8S préconfigurée

Master (déclaration fonctionnelle sans autre configuration) :

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
