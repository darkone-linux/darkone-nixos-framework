# Module build-farm — délégation des builds à une machine puissante

## Objectif

Créer un module DNF `build-farm` permettant de déclarer, via `config.yaml`,
une machine du réseau comme builder distant Nix (distributed builds) pour les
machines d'administration (déployeurs).

Cas concret : `ms-a2` (32 cœurs, 123 Gio RAM, quasi inactive) builde les
grosses dérivations à la place de `gfx` (déployeur, build central colmena).

## Motivation & périmètre des gains

- Le build du parc est **central** (`deployment.buildOnTarget = false`,
  cf. `dnf/lib/mk-configuration.nix:323`) : le déployeur builde tout.
- Une ferme de build accélère **uniquement la compilation réelle** :
  dérivations custom, overlays (ex. oxicloud), ISOs, et surtout les tests VM
  de `just check-all` (dérivations `nixos-test`, gourmandes en KVM/cœurs).
- Elle n'accélère **ni** l'évaluation Nix (mono-thread, sur le déployeur),
  **ni** les téléchargements substitués depuis cache.nixos.org.
- Orthogonal au temps de copie des closures (`buildOnTarget`, substitution
  côté destination) : combinable, mais hors périmètre de ce module.

:::caution[WAN]
Le builder peut être dans une autre zone (ms-a2 en cp, gfx en ag) : chaque
build délégué transfère inputs + outputs via le tailnet. Rentable pour les
grosses dérivations, contre-productif pour les petites. D'où le ciblage par
`supportedFeatures` (le scheduler Nix ne délègue que ce qui les requiert) et
un `max-jobs` local non nul sur le client.
:::

## Architecture

Pattern `nix-cache.nix` (résolution serveur/clients depuis `network.services`) :

- **Serveur** : l'hôte qui liste `build-farm` dans ses `services` de
  `config.yaml`. Service **global** (un seul pour tout le réseau, joignable
  cross-zone via tailnet — résolution IP par `dnfLib.preferredIp`).
- **Clients** : les machines d'administration uniquement — gate sur
  `config.darkone.admin.nix.enable` (profil `admin-desktop`), PAS toutes les
  machines de la zone (différence avec nix-cache).
- Le serveur ne doit jamais être son propre client (cf. `isServer`/`isClient`
  dans `nix-cache.nix`).

## Prérequis déjà en place (ne rien re-créer)

- `nix.settings.trusted-users` contient déjà `nix` sur toute la flotte
  (`modules/system/core.nix:179`) → le serveur accepte déjà les imports du
  protocole de build distant.
- La clé publique du user `nix` (`usr/secrets/nix.pub`) est autorisée sur
  chaque hôte (`modules/system/core.nix:139`) → l'accès SSH `nix@<serveur>`
  existe (c'est la clé colmena).

## Implémentation

### Fichiers

- Module : `dnf/modules/service/build-farm.nix` (norme DNF,
  cf. `dnf/modules/service/AGENTS.md`). `just generate` régénère les
  `default.nix` (ne pas les éditer à la main).
- Déclaration : entrée `build-farm` dans `dnf/config/modules.nix` —
  `reverseProxy = false`, pas de `uniquePerZone` (service global unique).

### Côté serveur (mkIf isServer)

- Rien d'obligatoire côté accès (cf. prérequis). Le module sert surtout à
  marquer l'hôte dans `network.services` et à garantir les features :
  - vérifier/activer KVM si le matériel le permet (nécessaire pour
    `nixos-test`) ; sinon ne pas annoncer la feature.
  - éventuel tuning : `nix.settings.max-jobs`, `cores` (options du module).
- Pas d'ouverture firewall : tout passe par SSH (22, déjà ouvert).

### Côté client (mkIf isClient, gate darkone.admin.nix.enable)

```nix
nix.distributedBuilds = true;
nix.buildMachines = [{
  hostName = <preferredIp du serveur>;   # cross-zone -> IP tailnet
  sshUser = "nix";
  sshKey = <chemin clé privée du user nix local>;  # cf. point d'attention
  system = "x86_64-linux";
  maxJobs = <option, défaut 8>;
  speedFactor = <option, défaut 2>;
  supportedFeatures = [ "big-parallel" "kvm" "nixos-test" "benchmark" ];
}];

# Le builder substitue lui-même ses dépendances (via son cache de zone)
# au lieu de tout recevoir du client -> économise le WAN.
nix.settings.builders-use-substitutes = true;
```

- Garder `nix.settings.max-jobs` local > 0 : les petites dérivations restent
  locales, seules celles qui requièrent une feature du builder partent.

### Points d'attention

- **Clé SSH de nix-daemon** : les builds distants sont lancés par le démon
  (root), pas par le user `nix`. `sshKey` doit pointer la clé privée déployée
  du user `nix` local (celle utilisée par colmena), lisible par root.
  Vérifier le chemin réel au dev (home du user `nix` sur le déployeur).
- **Host key** : root n'a pas le known_hosts du user `nix`. Fournir
  `programs.ssh.knownHosts.<serveur>` (clé hôte publique committable) ou
  `publicHostKey` (base64) dans l'entrée `buildMachines`.
- **KVM sur le serveur** : n'annoncer `kvm`/`nixos-test` que si `/dev/kvm`
  est effectif (sinon les tests VM échoueront en boucle sur le builder).
- **Éval standalone** : comme nix-cache/harmonia, rester null-safe quand le
  service est absent ou en mode `darkone.test.standalone` (workspace
  consommateur inexistant).
- Chemins consommateur (`usr/secrets/...`) uniquement via `workDir`
  (frontière framework ↔ consommateur).

## Options du module (proposition)

- `darkone.service.build-farm.enable` (mkEnableOption)
- `maxJobs` (int, défaut 8) — jobs parallèles annoncés côté client
- `speedFactor` (int, défaut 2)
- `supportedFeatures` (liste, défaut `[ "big-parallel" "kvm" "nixos-test" "benchmark" ]`)
- Tuning serveur éventuel : `serverMaxJobs`, `serverCores` (défauts nixpkgs)

## Utilisation

```yaml
# etc/config.yaml
hosts:
  - hostname: "ms-a2"
    # ...
    services:
      build-farm:
        global: true # joignable cross-zone (tailnet)
```

Aucune config côté gfx : tout hôte `admin-desktop` (donc
`darkone.admin.nix.enable`) devient client automatiquement.

## Tests

- Scénario eval dédié : copier un variant sous
  `tests/workspaces/node/configs/<variant>/`, ajouter `build-farm` au
  `config.yaml`, `just fixtures generate`, enregistrer dans `eval-all.nix`,
  `git add` des nouveaux fichiers (flakes ignorent le non-tracké).
- Vérifier les deux profils : hôte serveur (options nix serveur posées) et
  hôte client admin (`buildMachines` généré, IP tailnet résolue).

## Déroulé des opérations

1. Étudier `nix-cache.nix` (résolution serveur/clients, null-safety) et la
   norme module (`dnf/modules/service/AGENTS.md`).
2. Vérifier sur gfx le chemin réel de la clé privée du user `nix` et le
   format retenu pour la host key du serveur.
3. Développer le module + entrée `config/modules.nix` + tests eval.
4. `just clean` puis validation : `nix store ping --store ssh://nix@ms-a2`
   côté root, puis un build test avec `requiredSystemFeatures = [ "big-parallel" ]`
   et vérifier qu'il s'exécute sur ms-a2 (`nix log`, charge distante).
5. Mesurer sur `just check-all` (tests VM) avant/après.
