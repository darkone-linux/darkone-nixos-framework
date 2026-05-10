## A faire

### En cours

- [ ] Linux durci selon les [recommandations ANSSI](https://messervices.cyber.gouv.fr/guides/recommandations-de-securite-relatives-un-systeme-gnulinux).
  - [x] [Architecture modulaire](https://darkone-linux.github.io/en/ref/modules/#security-modules) pour l'activation et le paramétrage des règles.
  - [ ] Gestion de noyaux durcis avec paramètres statiques durcis (profils, mise en cache)
  - [ ] Implémentation des règles.
- [ ] Optimisation des développements par l'IA ([cf. doc en ligne](https://darkone-linux.github.io/fr/doc/introduction/#utilisation-de-lia)).
- [ ] SSO avec [Kanidm](https://kanidm.com/) ([module nix](https://search.nixos.org/options?channel=unstable&query=services.idm))
  - [x] Implémentation du module IDM.
  - [x] Configuration paramétrable pour chaque service (config inconditionnelle) et instance de service (config conditionnelle).
  - [ ] Réplicats de zone.
- [ ] Ponts Mautrix pour Matrix (whatsapp, telegram, messenger, discord).
  - [x] POC -> implémentation locale.
  - [ ] Généralisation -> implémentation paramétrable pour chaque user.
- [ ] IA générative self-hosted + agents.
  - [x] Interface Open WebUI + Ollama + Modèles locaux.
  - [x] Comptes OIDC, cloisonnés pour chaque utilisateur.
  - [ ] Agents MCP personnels.
  - [ ] Générateur d'images et de médias.
  - [ ] Conf OpenCode / Claude Code optimisée pour les développeurs.
- [x] Remplacer le générateur PHP par un générateur Rust + parseur nix complet.
  - [x] Implémentation + tests.
  - [ ] Corrections et optimisations à l'utilisation.
- [ ] Tests unitaires + tests de recette.
  - [ ] TU pour tout ce qui est dans lib/.
  - [ ] Déplacement dans lib/ de tout algorithme un peu complexe ou comportant de possibles effets de bords, sous forme de fonctions durcies et testées, simplifiant le code utile des modules.
- [ ] Module LaSuite Docs
  - [x] Implémentation de base. 
  - [ ] Tests et stabilisation.
  - [ ] Module MinIO utile à LaSuite Docs.
    - [x] Implémentation (version locale ou distante).
    - [ ] Tests et stabilisation.

### Planifié

- [ ] Services -> réorganiser la manière dont on les déclare -> services uniques + avec sous-domaine fixe, sous-domaines interdits déclarables, services multiples avec OIDC.
- [ ] Séparer en plusieurs projets
  - [ ] Projet 1 : framework (code commun à toutes les instances, `dnf/`)
  - [ ] Projet 2 : boilerplate pour implémentation locale qui étend le framework (input flake + override-input en dev, `usr/`)
  - [ ] Projet 3 : Générateur Rust séparé (`src/generator`).
  - [ ] Projet 4 : Documentation (`doc/`)
- [ ] Commandes d'introspection pour lister les hosts, users, modules activés par host, etc.
- [ ] Automatisation des secrets OIDC et similaires.
- [ ] Corriger l'arbre de démarrage des services, un redémarrage de passerelle ou du HCS laisse certains services (kanidm, prometheus-node-exporter, mnt-nfs-homes) en berne.
- [ ] Suite de tests de recette complète, intégrée à une stratégie d'intégration continue déclarative et utilisable par chaque instance DNF.
- [ ] Gestion optimale des traductions FR <-> EN avec fichiers MO + agent IA dédié.

### Axes d'amélioration

- [ ] Remplacer Nextcloud par un équivalent plus simple, stable, performant et OIDC natif
  - [ ] [Ocis](https://doc.owncloud.com/ocis/next/), [OpenCloud](https://opencloud.eu/en/features) ([nix](https://search.nixos.org/options?channel=unstable&query=services.opencloud)), [Filebrowser Quantum](https://filebrowserquantum.com/en/) ([oidc](https://filebrowserquantum.com/en/docs/configuration/authentication/oidc/)), [OxiCloud](https://github.com/DioCrafts/OxiCloud) (un peu jeune)
  - [ ] [Rustical](https://github.com/lennart-k/rustical) ([pr nix](https://github.com/NixOS/nixpkgs/pull/424188), [oidc natif](https://lennart-k.github.io/rustical/setup/oidc/)) ou [Radical](https://github.com/Kozea/Radicale) ([nix](https://search.nixos.org/options?channel=unstable&query=services.radical)) pour calendar / contacts si nécessaire.
- [ ] Remplacer fail2ban par [CrowdSec](https://github.com/crowdsecurity/crowdsec) ([nix](https://search.nixos.org/options?channel=unstable&query=services.crowdsec)) ?
- [ ] Isolation des services : étudier la pertinence d'une isolation et le meilleur moyen d'isoler les services des serveurs (systemd-nspawn containers.xxx, Docker / Podman, systemd sandboxing...)
- [ ] SSO / Kanidm -> PAM
- [ ] Services isolés dans des conteneurs légers `systemd-nspawn` (optimal pour NixOS).

### A voir

- [ ] Intégration de [nixvim](https://nix-community.github.io/nixvim/).
- [ ] Gestion du secure boot avec [lanzaboote](https://github.com/nix-community/lanzaboote).
- [ ] Serveur de mails.
- [ ] Interface [headplane](https://github.com/tale/headplane) pour headscale.
- [ ] Ajout de Grafana Loki sur les logs Caddy pour avoir des stats de fréquentation.
- [ ] Synchro NTP locales, en particulier en cas d'isolation (coupure internet longue)
  - [ ] Serveur NTP authentifié sur chaque passerelle, pour synchro locale des horloges.
  - [ ] Synchronisation NTP des passerelles de zone avec GPS ou Galiléo.

### Fait

- [x] ~~Supprimer~~ Réorganiser les fichiers NixOS dans les espaces home manager.
- [x] Réseaux sociaux : ~~mattermost~~, [matrix](https://nixos.wiki/wiki/Matrix).
- [x] Partages Samba pour windows + linux (par machine).
- [x] [Nextcloud](https://wiki.nixos.org/wiki/Nextcloud) + configuration multi-postes.
- [x] Stratégie de sauvegarde avec [Restic](https://restic.net).
- [x] Création de noeuds avec [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) + [disko](https://github.com/nix-community/disko).
- [x] Services distribués (aujourd'hui les services réseau sont sur la passerelle).
- [x] Réseau distribué avec [Headscale](https://github.com/juanfont/headscale) + [WireGuard](https://www.wireguard.com/)
- [x] Serveurs et postes "externes" (administrable mais ne faisant pas partie du LAN).
- [x] Configuration pour réseau extérieur (https, dns, vpn...).
- [x] Let's encrypt
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
  - [x] Domaines locaux des machines -> 127.0.0.1 (shunt dnsmasq + adguard)
  - [x] Homepage GW -> accès aux services globaux installés sur le réseau hors GW

### Annulé

- [x] ~~Permettre de croiser les profils home manager + supprimer la hiérarchie des profils.~~

### TODO extraits du code source

- [ ] dnf/home/modules/advanced.nix:76 vscode a besoin d'un module home-manager
- [ ] dnf/home/modules/advanced.nix:103 hugo est deprecated, à remplacer par la version standard
- [ ] dnf/modules/standard/system/core.nix:186 Mettre en oeuvre wakeonlan à partir du mode veille
- [ ] dnf/home/modules/office.nix:25 Simplifier la recherche de la page d'accueil de la zone DNS
- [ ] dnf/home/modules/office.nix:145 Ajouter le support pour les profils enfants
- [ ] dnf/home/modules/office.nix:217 Détection automatique de la langue du navigateur
- [ ] dnf/home/modules/office.nix:294 Compléter et factoriser avec element.nix
- [ ] dnf/modules/standard/service/docs.nix:109 Configurer le stockage S3 pour les documents
- [ ] dnf/modules/standard/service/turn.nix:44 Activer TLS avec le service ACME pour le certificat turn
- [ ] dnf/modules/standard/service/turn.nix:65 Configurer un service ACME indépendant pour turn
- [ ] dnf/modules/standard/service/idm.nix:244 Affiner les paramètres openid connect
- [ ] dnf/modules/standard/service/idm.nix:374 Implémenter le service interne
- [ ] dnf/modules/standard/service/matrix.nix:3 Intégrer LiveKit pour les appels vidéo
- [ ] dnf/modules/standard/service/matrix.nix:4 Implémenter Synapse Admin avec Caddy
- [ ] dnf/modules/standard/service/matrix.nix:42 Configurer les permissions automatiques Mautrix
- [ ] dnf/modules/standard/service/matrix.nix:214 Optimiser la configuration Facebook Messenger
- [ ] dnf/modules/standard/service/matrix.nix:233 Ajouter le support Mautrix Discord
- [ ] dnf/modules/standard/service/matrix.nix:300 Évaluer l'utilité de la manhole pour l'administration
- [ ] dnf/modules/standard/service/matrix.nix:316 Détection automatique de web_client_location
- [ ] dnf/modules/standard/service/matrix.nix:382 Configurer limit_remote_rooms en cas de problèmes de performance
- [ ] dnf/modules/standard/service/matrix.nix:406 Configurer auto_join_rooms
- [ ] dnf/modules/standard/service/matrix.nix:453 Configurer l'inscription via email
- [ ] dnf/modules/standard/service/ai.nix:150 Ajouter le paramétrage automatique des modèles
- [ ] dnf/home/modules/music.nix:36 Implémenter le support audio
- [ ] dnf/home/modules/music.nix:50 Écrire la configuration Audacious dans .config/audacious/config
- [ ] dnf/home/modules/music.nix:139 Ajouter les utilisateurs au groupe audio
- [ ] dnf/home/modules/audio.nix:19 Compléter le module audio
- [ ] dnf/modules/standard/service/nextcloud.nix:101 Automatiser le serveur Whiteboard
- [ ] dnf/modules/standard/service/nextcloud.nix:132 Utiliser les secrets pour nextcloud
- [ ] dnf/modules/standard/service/nextcloud.nix:185 Rendre le service accessible en HTTPS
- [ ] dnf/modules/standard/service/nextcloud.nix:226 Activer la sauvegarde PostgreSQL
- [ ] dnf/modules/standard/system/services.nix:153 Factoriser avec tailscale.nix
- [ ] dnf/modules/standard/system/services.nix:385 Configurer les virtual hosts en HTTPS avec redirection permanente
- [ ] dnf/modules/standard/system/services.nix:428 Implémenter le proxy zonable
- [ ] dnf/modules/standard/system/services.nix:478 Configurer l'accès privé pour idm.domain.tld
- [ ] dnf/modules/standard/system/services.nix:515 Implémenter le proxy zonable
- [ ] dnf/modules/standard/system/services.nix:570 Intégrer les paramètres des widgets dans les paramètres du service
- [ ] dnf/modules/standard/service/homepage.nix:29 Implémenter l'internationalisation
- [ ] dnf/modules/standard/service/homepage.nix:64 Générer automatiquement les widgets selon les services actifs
- [ ] dnf/modules/standard/service/nfs.nix:28 Gérer les clients NFS de zones externes
- [ ] dnf/modules/standard/service/nfs.nix:105 Configurer all_squash avec idmapd
- [ ] dnf/modules/standard/service/nfs.nix:142 Implémenter l'automontage pour les ordinateurs portables
- [ ] dnf/modules/standard/service/searx.nix:103 Générer automatiquement les moteurs de recherche
- [ ] dnf/modules/standard/service/vaultwarden.nix:160 Définir une stratégie de sauvegarde locale
- [ ] dnf/modules/standard/service/headscale.nix:3 Simplifier et optimiser la configuration headscale
- [ ] dnf/modules/standard/service/headscale.nix:115 Configurer Derp relay, ACLs et OIDC
- [ ] dnf/modules/standard/service/headscale.nix:138 Configurer les ACLs headscale
- [ ] dnf/modules/standard/service/headscale.nix:196 Configurer OIDC pour headscale
- [ ] dnf/modules/standard/service/adguardhome.nix:68 Mettre à jour les clients depuis config.yaml
- [ ] dnf/modules/standard/service/tailscale.nix:24 Factoriser avec services.nix
- [ ] dnf/modules/standard/service/tailscale.nix:67 Configurer les paramètres au démarrage de tailscaled
- [ ] dnf/modules/standard/service/tailscale.nix:105 Implémenter la remontée d'information sur la synchro
- [ ] dnf/modules/standard/service/dnsmasq.nix:185 Nettoyer les adresses internes obsolètes
- [ ] dnf/modules/standard/service/dnsmasq.nix:236 Gérer les noms simples des autres zones
- [ ] dnf/modules/standard/service/restic.nix:23 Implémenter la sauvegarde avec restic
- [ ] dnf/modules/standard/system/i18n.nix:45 Détecter automatiquement le modèle de clavier
- [ ] dnf/modules/standard/system/i18n.nix:46 Détecter automatiquement la variante de clavier
- [ ] dnf/modules/mixin/host/portable.nix:12 Configurer les options de boot spécifiques pour les clés USB
- [ ] dnf/modules/mixin/profile/advanced.nix:8 Implémenter un module home-manager
- [ ] dnf/modules/standard/service/home-assistant.nix:15 Compléter la configuration Home Assistant
- [ ] dnf/modules/standard/service/home-assistant.nix:30 Ajouter les dépendances pour une configuration de base
- [ ] dnf/modules/standard/service/audio.nix:26 Activer le support JACK si nécessaire
- [ ] dnf/modules/mixin/host/server.nix:43 Activer cette fonctionnalité si utile
- [ ] dnf/hosts/templates/install.nix:5 Détecter automatiquement la disposition du clavier
- [ ] dnf/home/modules/mime.nix:9 Ajouter le support MIME
- [ ] dnf/home/modules/mime.nix:70 Définir les applications par défaut
- [ ] dnf/modules/standard/service/monitoring.nix:14 Implémenter oauth2-proxy
- [ ] dnf/modules/standard/service/monitoring.nix:63 Implémenter l'accès par mot de passe
- [ ] dnf/modules/standard/service/monitoring.nix:85 Activer oauth2-proxy
