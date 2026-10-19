# Votre réseau DNF

Bienvenue ! Ce dossier **est** votre réseau. Chaque machine, chaque
utilisateur et chaque service y est décrit, sous forme de code, puis construit
par le [Darkone NixOS Framework](https://github.com/darkone-linux/darkone-nixos-framework)
(DNF). Rien ne se règle à la main sur les hôtes : on modifie un fichier ici, on
déploie, et la machine suit.

Un seul fichier à connaître pour commencer : **`etc/config.yaml`**. Ses
commentaires expliquent chaque champ, et votre éditeur les affiche au survol.

## Où est quoi

| Chemin | Contenu |
|---|---|
| `etc/config.yaml` | Votre réseau : zones, utilisateurs, hôtes, services |
| `usr/machines/<hôte>/` | Fichiers d'un hôte (`configuration.nix` est à vous) |
| `usr/users/<login>/` | Personnalisations d'un utilisateur |
| `usr/modules/`, `usr/home/` | Vos propres modules NixOS et Home Manager |
| `usr/secrets/` | Clés et secrets chiffrés : gérés par `just`, jamais à la main |
| `var/generated/` | Écrit par `just generate` : à commiter, jamais à éditer |
| `dnf/` | Lien vers la version du framework épinglée par ce projet |

## Au quotidien

Tout se lance depuis ce dossier (`cd /etc/nixos`) :

```sh
just                  # toutes les commandes, par groupe
just clean            # vérifie et formate, avant chaque commit
just apply-local      # déploie cette machine
just apply <hôte>     # déploie un autre hôte
git add -A && git commit -m "…"
```

> [!IMPORTANT]
> Commitez avant de construire : Nix ne voit que les fichiers suivis par git.

## Étapes suivantes

Votre poste d'administration est prêt, c'est l'étape 1 sur 4. Ensuite, à
votre rythme :

1. **La passerelle** : une petite machine allumée en permanence, entre la box
   Internet et le réseau : adresses fixes, noms locaux, services partagés.
   [Installer la passerelle](https://darkone-linux.github.io/fr/doc/admin-guide/install/gateway/)
2. **Serveurs et services** : fichiers, photos, messagerie, mots de passe…
   chacun déclaré dans `etc/config.yaml`.
   [Le catalogue des services](https://darkone-linux.github.io/fr/doc/admin-guide/operate/services/)
3. **Internet** : un serveur de coordination relie vos sites et publie vos
   services.
   [Le serveur de coordination](https://darkone-linux.github.io/fr/doc/admin-guide/install/hcs/)

## Protéger vos clés

Les clés de tout le réseau sont sur cette machine. Rangez la clé USB de
sauvegarde loin d'elle, et rafraîchissez-la après tout changement de clés :

```sh
just backup-admin /dev/disk/by-label/<étiquette>
```

Sans sauvegarde, un disque perdu ou cassé emporte toutes les clés du réseau.

## Aide

- Documentation : [Français](https://darkone-linux.github.io/fr/) •
  [English](https://darkone-linux.github.io/en/)
- Premier réseau, pas à pas :
  [guide d'installation](https://darkone-linux.github.io/fr/doc/admin-guide/install/first-network-installation/)
- Mettre à jour le framework :
  [versions](https://darkone-linux.github.io/fr/doc/admin-guide/maintain/versions/)
- Code source : [framework](https://github.com/darkone-linux/darkone-nixos-framework) •
  [générateur](https://github.com/darkone-linux/dnf-generator) •
  [déploiement de référence](https://github.com/darkone-linux/dnf-example)

## Démarrer sans l'assistant

L'image d'installation DNF (`darkone new`) écrit ce projet pour vous. Partant
plutôt du [template GitHub](https://github.com/darkone-linux/dnf-boilerplate)
ou de `nix flake new` :

```sh
nix flake new -t github:darkone-linux/darkone-nixos-framework mon-reseau
cd mon-reseau && git init -b main && git add -A
nix run .#init                # pose le lien dnf/ vers le framework
```

Décrivez ensuite votre réseau dans `etc/config.yaml` et installez le premier
hôte : voir [Créer le projet](https://darkone-linux.github.io/fr/doc/admin-guide/install/first-network-installation/#créer-le-projet)
dans le guide d'installation.
