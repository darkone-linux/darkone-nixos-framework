# Darkone NixOS Framework

> [!NOTE]
> La [documentation technique](https://darkone-linux.github.io) en ligne.


## Présentation aux utilisateurs (non technique)

### De quoi s'agit-il ?

Un cloud auto-hébergé composé d'un réseau, de services, d'ordinateurs :

- Un grand "réseau local" (VPN), rapide et protégé des publicités et des malwares.
- Des services pour gérer ses données : documents personnels, images, médias.
- Des systèmes Linux (optionnels) pré-installés et très faciles pour non-informaticiens.

### Quels avantages ?

- 🔐 Sécurité maximale (chiffrement) et 100 % souveraine : nos données restent à nous.
- 🚫 Elles ne peuvent être revendues aux assurances, publicitaires et moteurs d’IA.
- 🔁 Sauvegardes 3-2-1 automatisées, chiffrées et distribuées.
- 🕐 Outils, programmes et services utiles, simples, qui font gagner du temps.
- 👶 Profils et services 100 % sécurisés pour les enfants.
- 🔑 Un seul mot de passe pour tous les services, y compris externes (SSO + coffre-fort).

### Principaux services

Pour tous ces services, une seule connexion suffit ! (pas besoin de rentrer 36 fois 36 mots de passe)

| | Nom | Utilité |
| ----- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 🔐 | [Vaultwarden](https://vaultwarden.net) | Mon coffre-fort à mots de passe, clés et données critiques. Avec les plugins Bitwarden (navigateur, smartphones), je génère et utilise des mots de passe forts pour tous mes comptes. |
| ☁️ | [Nextcloud](https://nextcloud.com) | Mon cloud personnel dans lequel je peux déposer tous mes fichiers et données, les partager comme je veux, les synchroniser avec mes ordinateurs et smartphones. |
| 🖼️ | [Immich](https://immich.app) | Mes photos et vidéos personnelles, une interface fluide et conviviale avec reconnaissance faciale et recherche IA totalement auto-hébergée. |
| 💬 | [Matrix](https://matrix.org) | Application type « WhatsApp » de messagerie et visio, que les enfants peuvent utiliser en toute sécurité (réseau Matrix non fédéré), avec possibilité d’agréger WhatsApp, Telegram, Messenger, etc. |
| 🎬 | [Jellyfin](https://jellyfin.org) | Une médiathèque à la « Netflix » pour les films et la musique, avec une interface très conviviale. |
| 🧑‍💻 | [Forgejo](https://forgejo.org) | Au service de ceux qui utilisent Git pour leurs sources et données (versionnage de documents). |
| 🛑 | [AdGuardHome](https://adguard.com/en/adguard-home/overview.html) | Un filtre anti-publicité et anti-malware qui accélère sensiblement la navigation sur Internet et renforce la sécurité. |
| 🍽️ | [Mealie](https://github.com/hay-kot/mealie) | Application de recettes de cuisine très bien conçue et agréable à utiliser. |
| 📝 | [Outline](https://www.getoutline.com) | Pour prendre des notes individuelles ou collectives. (Outline est une application de prise de notes/wiki auto-hébergeable; site officiel fourni). |


> [!NOTE]
> Les ordinateurs du réseau (sous Linux NixOS) sont 100% pré-installés avec tous les programmes, comptes et configurations.

### Profils d'utilisateurs

Chaque utilisateur est lié à un “profil” (au choix et interchangeable), qui détermine : 

* Les programmes installés (éducation, bureautique, jeux…).
* Les configurations (accès internet, services de communication…).

| **Profil** | **Description** |
|----|----|
| ⚪&nbsp;minimal | Compte épuré avec le strict minimum de programmes. |
| 🔵&nbsp;normal | Pour utilisateur bureautique non-informaticien, avec l'essentiel des programmes. |
| 🟣&nbsp;avancé | Pour utilisateur informaticien, avec des outils avancés. |
| 🔴&nbsp;admin | Compte avancé pour administrer le réseau et les systèmes (expert Linux et Nix requis). |
| 🎨&nbsp;créateur | Pour créateur multimédia, avec tout ce qu'il faut pour créer vidéo, musique, photo / image. |
| 📘&nbsp;étudiant | Des outils utiles d'organisation, prise de notes, entraînement pour les étudiants. |
| 🎮&nbsp;Joueur | Un système épuré avec essentiellement des jeux (utilisé pour les LANs). |
| 🎒&nbsp;ado | Des programmes éducatifs et funs, jeux et services pour commencer avec internet. |
| 🧩&nbsp;enfant | Logiciels éducatifs pour apprendre, jeux pour entraîner son cerveau, pas d'accès internet. |
| 🧸&nbsp;baby | Logiciels limités pour apprendre à utiliser la souris, jouer avec les nombres, formes, etc. |

### Types d'ordinateurs

Notre réseau local est une bulle sécurisée composé de "noeuds" (ordinateurs) qui peuvent être :

| Type | Utilité |
| ---------------------------- | ------------------------------------------------------------------------------------------------------ |
| 📱 Mon smartphone, tablette | Je peux me brancher au réseau et à tous ses services avec mes périphériques portables. |
| 💻&nbsp;Mon&nbsp;ordi&nbsp;et&nbsp;système&nbsp;adoré | Sous Windows, macOS ou Linux, peu importe, je peux aussi me brancher simplement au réseau. |
| ❄️ Ordi au top sous NixOS ! | Tout est installé, configuré, sécurisé. J'ai juste à me connecter et à travailler, jouer, me divertir. |
| 🗄️ Serveur | Un ordinateur qui reste allumé pour y héberger des services (Jellyfin, Immich, sauvegarde, etc.). |
| 🌐 Passerelle | Un petit bijou spécial qui fait le lien entre notre réseau local et Internet (pare-feu, routeur, VPN). |
| 🎼 Serveur de coordination | Ce sombre individu est le « chef d’orchestre » de notre réseau local sur Internet (VPS). |

## Présentation technique

## Une configuration multi-utilisateur, multi-hôte et multi-service

- 🔥 [Déclaratif, reproductible, immuable](https://nixos.org/).
- 🚀 [Modules](https://darkone-linux.github.io/ref/modules/) prêts à l’emploi.
- ❄️ [Configuration](https://github.com/darkone-linux/darkone-nixos-framework/blob/main/usr/config.yaml) simple.
- 🧩 [Organisation](https://darkone-linux.github.io/doc/introduction/#structure) cohérente.
- 🌎 Un [réseau complet](#one-configuration-a-full-network).

Ce projet évolue en fonction de mes besoins. Si vous souhaitez être informé des prochaines versions stables, merci de me le faire savoir sur [GitHub](https://github.com/darkone-linux/darkone-nixos-framework) ou en vous abonnant à ma [chaîne YouTube](https://www.youtube.com/@DarkoneLinux) (FR). Merci !

## Fonctionnalités principales

| | Fonctionnalité | Description |
|---|---------------|-------------|
| ⚙️ | Tout-automatisé | Installation et mise à jour auto des hôtes avec [nixos-anywhere](https://github.com/nix-community/nixos-anywhere), [disko](https://github.com/nix-community/disko) et [colmena](https://github.com/zhaofengli/colmena) |
| 👤 | Profils utilisateurs | [Profils](https://github.com/darkone-linux/darkone-nixos-framework/tree/main/dnf/home/profiles) et [modules](https://darkone-linux.github.io/ref/modules/#home-manager-modules) utilisateurs avec [Home Manager](https://github.com/nix-community/home-manager) (admin, gamer, débutant…) |
| 🖥️ | Profils d’hôtes | [Profils d’hôtes](https://darkone-linux.github.io/ref/modules/#-darkonehostdesktop) (serveurs, conteneurs, nœuds réseau, postes de travail…) |
| 🌐 | VPN Tailnet | [VPN maillé](https://fr.wikipedia.org/wiki/R%C3%A9seau_maill%C3%A9) avec [headscale](https://headscale.net/) + [tailscale](https://tailscale.com/) et [sous-réseaux indépendants](#une-configuration-pour-un-réseau-complet) |
| 🛡️ | Stop Publicités | Internet sécurisé et sans publicité avec [AdguardHome](https://adguard.com/fr/adguard-home/overview.html) et un pare-feu efficace |
| 🧩 | Authentification unique | SSO avec [Kanidm](https://kanidm.com/) : une seule identité pour (presque) tous les services |
| 🤗 | Services intelligents | [Immich](https://immich.app/), [Nextcloud](https://nextcloud.com/), [Forgejo](https://forgejo.org/), [Vaultwarden](https://github.com/dani-garcia/vaultwarden), [Mattermost](https://mattermost.com/), [Jellyfin](https://jellyfin.org/), [etc.](https://darkone-linux.github.io/ref/modules/#-darkoneserviceadguardhome) |
| 💻 | GNOME épuré | Hôtes NixOS avec un [GNOME](https://www.gnome.org/) allégée et des applications stables et utiles |
| 💾 | Sauvegardes 3-2-1 | Sauvegardes robustes, simplifiées et distribuées avec [Restic](https://restic.net/) |
| 🤖 | IA Générative | IA générative locale et sécurisée, avec [Open WebUI](https://openwebui.com/) et [Ollama](https://ollama.com/) |
| 🏠 | Page d’accueil | [Page d’accueil automatisée](#page-daccueil-dynamique) → accès rapide à tous les services configurés |

## Sous le capot

| | Spécificité | Description |
|---|---------------|-------------|
| ❄️ | Déclaratif et immuable | Configuration reproductible basée sur [Nix / NixOS](https://nixos.org/) et son écosystème |
| 🔑 | Sécurité renforcée | Stratégie de sécurité simple et fiable, reposant sur [sops-nix](https://github.com/Mic92/sops-nix) |
| 📦 | Modules haut niveau | [Modules NixOS haut-niveau](https://darkone-linux.github.io/ref/modules), faciles à activer et à configurer |
| 📐 | Architecture | [Architecture extensible et scalable](https://darkone-linux.github.io/doc/introduction/#structure), cohérente et personnalisable |
| ✴️ | Proxy inverse | Services distribués à travers le réseau via des proxies sous [Caddy](https://github.com/caddyserver/caddy) |
| 🛜 | Réseau automatisé | Plomberie réseau zero-conf (DNS, DHCP, pare-feu…) avec [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) |

### État des services SSO (OIDC / Oauth2)

- Oauth2 = permet une connexion oauth2 / oidc
- Natif = pas besoin de plugin ou autre, on peut paramétrer directement
- PKCE = prend en charge PKCE
- Déclaratif = tous les paramètres peuvent être déclarés dans la configuration
- OK = implémentation fonctionnelle

| Application | Oauth2 | Natif | PKCE | Déclaratif | OK | Commentaires |
| -------------- | ------ | ----- | ---- | ---------- | --- | ----------------------------------- |
| Outline | ✅ | ✅ | ✅ | ✅ | ✅ | Fonctionne parfaitement |
| Mealie | ✅ | ✅ | ✅ | ✅ | ✅ | Fonctionne parfaitement |
| Vaultwarden | ✅ | ✅ | ✅ | ✅ | ✅ | Fonctionne parfaitement |
| Matrix Synapse | ✅ | ✅ | ✅ | ✅ | ✅ | Marche bien (+Element +Coturn) |
| Open WebUI | ✅ | ✅ | ✅ | ✅ | ✅ | Marche bien (+Ollama) |
| Immich | ✅ | ✅ | ✅ | ⚠️ | ✅ | Configuration manuelle |
| Forgejo | ✅ | ✅ | ✅ | ❌ | ✅ | Configuration manuelle |
| Nextcloud | ✅ | ❌ | ❌ | ❌ | ✅ | Plugin + configuration manuelle |
| Oauth2 Proxy | ✅ | ✅ | ✅ | ✅ | ⚠️ | Gestion multi-service problématique |
| Jellyfin | ✅ | ❌ | ❔ | ❔ | ❔ | En cours |
| AdGuardHome | ❌ | ❌ | ❌ | ❌ | ❔ | Via Oauth2 Proxy |
| ~~Mattermost~~ | ❌ | ❌ | ❌ | ❌ | ❌ | Plus de Oauth2 pour l'édition TEAM |

## Page d'accueil dynamique

![Homepage](doc/src/assets/homepage-screenshot.png)

## Une configuration pour un réseau complet

![New network architecture](doc/src/assets/reseau-darkone-2.png)

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
 - hostname: "darkone-laptop" # Nom du host
 name: "An admin laptop" # Description du host
 profile: admin-laptop # Profil du host -> fonctionnalités à installer
 users: [ "darkone", "john" ] # Utilisateurs à installer sur le host
 groups: [ "admin" ] # Groupes d'utilisateurs à installer
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

## Administration simplifiée avec Just

![Just DNF Command](doc/src/assets/just.png)

## Nettoyage & corrections automatiques simplifiées

![Just DNF Command](doc/src/assets/just-clean.png)

## Déploiement facile

Déploiement d'une nouvelle génération sur plusieurs hosts à partir de la même configuration.

![Just DNF Command](doc/src/assets/colmena.png)
