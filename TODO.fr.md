## A faire

### En cours

- [x] Correction des déclarations de partitions disko (swap trop petit + améliorations). (en test)
- [ ] Stratégie de test globale en 3 niveaux : tests unitaires, tests simulés (VMs légères), lab de staging complet (tests + introspection manuelle).
  - [x] [Cahier des charges](.specs/FULL-TEST-STRATEGY.fr.md).
  - [x] Tests unitaires (lib).
  - [x] Migration vers [nix-unit](https://nix-community.github.io/nix-unit/).
  - [x] Déplacement dans lib/ de tout algorithme un peu complexe ou comportant de possibles effets de bords, sous forme de fonctions durcies et testées, simplifiant le code utile des modules.
  - [x] Tests simulés (pkgs.testers.runNixOSTest) -> peu viable...
  - [ ] Lab de staging (microvm.nix ou nixos.vm)
- [ ] Linux durci selon les [recommandations ANSSI](https://messervices.cyber.gouv.fr/guides/recommandations-de-securite-relatives-un-systeme-gnulinux).
  - [x] [Architecture modulaire](https://darkone-linux.github.io/en/ref/modules/#security-modules) pour l'activation et le paramétrage des règles.
  - [ ] Gestion de noyaux durcis avec paramètres statiques durcis (profils, mise en cache)
  - [ ] Implémentation des règles.
- [ ] SSO avec [Kanidm](https://kanidm.com/) ([module nix](https://search.nixos.org/options?channel=unstable&query=services.idm))
  - [x] Implémentation du module IDM.
  - [x] Configuration paramétrable pour chaque service (config inconditionnelle) et instance de service (config conditionnelle).
  - [x] Brancher Grafana.
  - [ ] Réplicats de zone (activation auto selon les services idm déclarés). -> FAIL
    - [x] Mécanisme de réplication : auto par scénario (idm/HCS seul = instance unique ; idm/passerelle sans HCS = autonome ; idm/HCS + passerelles = réplication). HCS supplier (WriteReplica), passerelles WriteReplicaNoUI puis ReadOnlyReplica, bootstrap 2 phases (`just idm-sync-certs`).
    - [ ] Joignabilité locale du réplicat pour le login hors-ligne : vhost Caddy servant le FQDN global `idm.<network.domain>` sur la passerelle + bascule DNS dnsmasq → IP passerelle. À câbler/valider en déploiement réel multi-hôtes.
- [ ] Ponts Mautrix pour Matrix (whatsapp, telegram, messenger, discord).
  - [x] POC -> implémentation locale.
  - [ ] Généralisation -> implémentation paramétrable pour chaque user.
  - [ ] Stabilisation et simplification -> certains ponts (whatsapp, discord) sont compliqués et instables.
- [ ] Module d'IA générative self-hosted + agents.
  - [x] Interface Open WebUI + Ollama + Modèles locaux.
  - [x] Comptes OIDC, cloisonnés pour chaque utilisateur.
  - [ ] Agents MCP personnels.
  - [ ] Générateur d'images et de médias.
  - [x] Conf OpenCode / Claude Code optimisée pour les développeurs.

### Planifié

- [ ] Commandes d'introspection pour lister les hosts, users, modules activés par host, etc.
- [ ] Automatisation des secrets OIDC et similaires.
- [ ] Corriger l'arbre de démarrage des services, un redémarrage de passerelle ou du HCS laisse certains services (kanidm, prometheus-node-exporter, mnt-nfs-homes) en berne.
- [ ] Suite de tests de recette complète, intégrée à une stratégie d'intégration continue déclarative et utilisable par chaque instance DNF.
- [ ] Officialiser le projet auprès du public.
  - [ ] Politique de versionning, packaging, changelog, diffusion.
  - [ ] "Getting Started" très simple, rapide et efficace.
  - [ ] ISO NixOS + DNF facile à installer.
  - [ ] Documentation user-friendly.

### Axes d'amélioration

- [ ] Remplacer Nextcloud par un équivalent plus simple, stable, performant et OIDC natif
  - [ ] [Ocis](https://doc.owncloud.com/ocis/next/), [OpenCloud](https://opencloud.eu/en/features) ([nix](https://search.nixos.org/options?channel=unstable&query=services.opencloud)), [Filebrowser Quantum](https://filebrowserquantum.com/en/) ([oidc](https://filebrowserquantum.com/en/docs/configuration/authentication/oidc/)), [OxiCloud](https://github.com/DioCrafts/OxiCloud) (un peu jeune)
  - [ ] [Rustical](https://github.com/lennart-k/rustical) ([pr nix](https://github.com/NixOS/nixpkgs/pull/424188), [oidc natif](https://lennart-k.github.io/rustical/setup/oidc/)) ou [Radical](https://github.com/Kozea/Radicale) ([nix](https://search.nixos.org/options?channel=unstable&query=services.radical)) pour calendar / contacts si nécessaire.
- [ ] Remplacer fail2ban par [CrowdSec](https://github.com/crowdsecurity/crowdsec) ([nix](https://search.nixos.org/options?channel=unstable&query=services.crowdsec)) ?
- [ ] Isolation des services : étudier la pertinence d'une isolation et le meilleur moyen d'isoler les services des serveurs (systemd-nspawn containers.xxx, Docker / Podman, systemd sandboxing...)
- [ ] SSO / Kanidm -> PAM
- [ ] Services isolés dans des conteneurs légers `systemd-nspawn` (optimal pour NixOS).
- [ ] Stratégie CD par palier + remontées d'info -> environnements de... development, staging, canary, unstable, stable
- [ ] Sécurité : [canary tokens](https://canarytokens.org/).
- [ ] Mise à l'échelle : remplacer colmena par Salt-like ou Ansible-like + LDAP...
- [ ] CI avec [Hercule-CI](https://github.com/apps/hercules-ci) -> si le projet grossit.

### A voir

- [ ] Intégration de [nixvim](https://nix-community.github.io/nixvim/).
- [ ] Gestion du secure boot avec [lanzaboote](https://github.com/nix-community/lanzaboote).
- [ ] Serveur de mails.
- [ ] Interface [headplane](https://github.com/tale/headplane) pour headscale.
- [ ] Synchro NTP locales, en particulier en cas d'isolation (coupure internet longue)
  - [ ] Serveur NTP authentifié sur chaque passerelle, pour synchro locale des horloges.
  - [ ] Synchronisation NTP des passerelles de zone avec GPS ou Galiléo.
- [ ] Stratégie de scalabilité horizontale.
  - [ ] Fragmentation et isolation des services et des données utilisateur.
  - [ ] Instanciations pilotées par un orchestrateur type [k8s](https://github.com/kubernetes/kubernetes).
  - [ ] Stratégies de sauvegarde, sécurité, performances.
- [ ] Instance publique basée sur le ndd darkone.yt. (cf. scalabilité horizontale ci-dessus)
- [ ] Optimisation des développements par l'IA ([cf. doc en ligne](https://darkone-linux.github.io/fr/doc/introduction/#utilisation-de-lia)).
- [ ] Module MinIO
  - [x] Implémentation (version locale ou distante).
  - [ ] Tests et stabilisation.

### Abandonnés

- [ ] Voir si [Zabbix](https://www.zabbix.com/fr) ne serait pas une bonne alternative / complément à Prometheus / Grafana. -> Alertmanager

### Fait

- [x] Remontée d'information et alertes avec Alertmanager + Prometheus.
- [x] Cache de store harmonia.
- [x] Gestion optimale des traductions FR <-> EN ~~avec fichiers MO~~ avec un mécanisme de taguage + agent IA dédié.
- [x] Services -> réorganiser la manière dont on les déclare -> services uniques + avec sous-domaine fixe, sous-domaines interdits déclarables, services multiples avec OIDC.
- [x] Update + déploiement complet du réseau.
- [x] Remplacer le générateur PHP par un générateur Rust + parseur nix complet.
  - [x] Implémentation + tests.
  - [x] Corrections et optimisations à l'utilisation.
- [x] `just format`: nixfmt -> treefmt
- [x] Module LaSuite Docs
  - [x] Implémentation de base.
  - [x] Tests et stabilisation.
- [x] Séparer en plusieurs projets ([specs](.specs/SPLIT-PROJECT.fr.md))
  - [x] Projet 1 : framework (code commun à toutes les instances, `dnf/`)
  - [x] Projet 2 : boilerplate pour implémentation locale qui étend le framework (input flake + override-input en dev, `usr/`)
  - [x] Projet 3 : Générateur Rust séparé (`src/generator`).
  - [x] Projet 4 : Documentation (`doc/`)
- [x] Ajout de Grafana Loki sur les logs Caddy pour avoir des stats de fréquentation.
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
