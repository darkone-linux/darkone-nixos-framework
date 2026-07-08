# Matrix Authentication Service (MAS) — étude d'intégration

## Objectif

Déléguer toute l'authentification Synapse à MAS (next-gen auth OAuth2/OIDC),
en conservant Kanidm comme source d'identité. Cible d'usage DNF :

```nix
darkone.service.matrix.mas.enable = true;
```

... et rien d'autre. Câblage Kanidm, Synapse, proxy, bridges et secrets
entièrement automatique. Transparent pour les utilisateurs finaux.

## Motivation

- **Element X** (mobile next-gen) exige MAS ; QR-code login ; gestion de
  sessions moderne (revocation par device, portail self-service `/account`).
- L'auth interne legacy de Synapse (dont `oidc_providers`, utilisé
  aujourd'hui) est en voie de dépréciation ; matrix.org tourne sous MAS
  depuis 2025.
- MAS reste un composant Element officiel, packagé nixpkgs
  (`services.matrix-authentication-service`, module complet).

## État des lieux

- nixpkgs pinné (unstable) : module `services.matrix-authentication-service`
  avec `settings` freeform YAML, `extraConfigFiles` (secrets hors store),
  `createDatabase`, service durci `DynamicUser=true`.
- Synapse ≥ 1.136 : section de config `matrix_authentication_service`
  (remplace l'ancien `experimental_features.msc3861`). Champs : `enabled`,
  `endpoint`, `secret`/`secret_path`. OK sur le pin actuel.
- DNF aujourd'hui (`modules/service/matrix.nix`) :
  - Synapse client OIDC direct de Kanidm (clientId `matrix`,
    `idp_id = "kanidm"`) ;
  - bridges mautrix ×5, double puppeting par appservice partagé ;
  - `friendRegistration` = tokens d'inscription **Synapse** (admin API) ;
  - bot `matrix-alertmanager` avec access token statique (sops).

## Architecture cible

```
client ──> caddy matrix.<domain>
             ├─ /_matrix/*, /_synapse/*        ──> synapse :8008
             ├─ /_matrix/client/*/login|logout|refresh ──> MAS :8090 (compat)
             └─ / (défaut: UI, /account, /oauth2, /upstream/callback, /assets)
                                               ──> MAS :8090
synapse <──介──> MAS : introspection de tokens + provisioning users
                 (secret partagé, localhost)
MAS ──> kanidm : upstream OIDC (le client OAuth2 "matrix" existant)
```

- **Un seul vhost** `matrix.<domain>` : pas de nouveau sous-domaine, pas de
  nouvelle entrée `network.services`, pas de DNS. Layout "same domain"
  documenté officiellement par MAS. MAS prend la route par défaut du vhost
  (portail de compte sur `/`, remplace l'actuel passage direct à Synapse qui
  n'y sert rien d'utile) ; Synapse garde `/_matrix/*` et `/_synapse/*` ;
  3 routes compat plus spécifiques remontent vers MAS (Caddy trie les
  matchers par spécificité, l'ordre des directives est indifférent).
- **Découverte cliente automatique** : Synapse relié à MAS sert lui-même
  `/_matrix/client/v1/auth_metadata` (MSC2965 final). Aucune modification du
  `.well-known/matrix/client` nécessaire. Optionnel : ajouter
  `org.matrix.msc2965.authentication` pour les vieux clients pre-1.15.
- **Flux de connexion** : Element → auth_metadata → MAS → bouton SSO
  "IDM" → Kanidm → callback MAS → provisioning du compte via l'admin API
  Synapse. Les amis (comptes locaux) se connectent par mot de passe, géré
  par MAS (base `passwords`), y compris via l'API legacy `m.login.password`
  (couche compat).

## Design du module

Tout dans `modules/service/matrix.nix` (nouveau bloc `mkIf cfg.mas.enable`),
pas de module séparé : MAS n'a de sens que collé à Synapse.

### Option

```nix
darkone.service.matrix.mas.enable = lib.mkOption {
  type = lib.types.bool;
  default = false;   # bascule à true après migration du parc
  description = "Delegate all authentication to Matrix Authentication Service.";
};
```

### Port

`config/network.nix` : `matrixAuth = 8090;` (libre). Listener MAS unique
bindé sur `params.ip` (comme Synapse) ; resources
`[ discovery human oauth compat graphql assets ]` ; listener `health`
sur loopback.

### MAS

```nix
services.matrix-authentication-service = {
  enable = true;
  createDatabase = true;              # postgres déjà présent
  extraConfigFiles = [ "/run/credentials/matrix-authentication-service.service/secrets.yml" ];
  settings = {
    http.public_base = params.href + "/";
    http.listeners = [ ... ];         # cf. ci-dessus
    matrix = {
      kind = "synapse";
      homeserver = network.domain;    # = server_name
      endpoint = "http://localhost:${toString synapsePort}";
      # secret -> secrets.yml
    };
    passwords.enabled = true;         # comptes amis
    account = {
      password_registration_enabled = cfg.friendRegistration.enable;
      registration_token_required = cfg.friendRegistration.enable;
      password_registration_email_required = false;  # pas de SMTP requis
    };
    upstream_oauth2.providers = [{
      id = "01JDNFKANIDM00000000000000";  # ULID FIXE, ne jamais changer
      human_name = "IDM";
      issuer = oidc.issuerUrl;            # kanidm/oauth2/openid/matrix
      client_id = clientId;
      # client_secret -> secrets.yml (fusion YAML par MAS)
      scope = "openid profile";
      token_endpoint_auth_method = "client_secret_basic";
      claims_imports = {
        localpart = {
          action = "require";
          # aligné sur l'actuel localpart_template synapse ; minijinja
          template = "{{ user.preferred_username | split('@') | first | lower }}";
        };
        displayname = { action = "suggest"; template = "{{ user.name }}"; };
      };
      # pour syn2mas : mappe les external_ids synapse existants
      synapse_idp_id = "oidc-kanidm";
    }];
  };
};
```

:::caution[Invariants]
- L'ULID du provider et `secrets.encryption` sont **immuables** après le
  premier démarrage (perte des liens upstream / des données chiffrées).
- Les localparts produits par `claims_imports.localpart` DOIVENT être
  identiques à ceux de l'actuel `localpart_template` Synapse, sinon les
  comptes migrés divergent. Valider le filtre minijinja `split` au premier
  déploiement (`mas-cli config check` est déjà exécuté en `ExecStartPre`
  par le module nixpkgs).
:::

### Secrets (sops, DynamicUser → LoadCredential)

`DynamicUser=true` : les fichiers sops (root:0400) ne sont pas lisibles par
le service. Passage par systemd credentials :

```nix
sops.templates.mas-secrets = {
  content = ''
    secrets:
      encryption: ${config.sops.placeholder.mas-encryption-secret}
      keys:
        - kid: dnf-rsa
          key: |
            ${lib. ... indentation du PEM ...}
    matrix:
      secret: ${config.sops.placeholder.mas-synapse-secret}
    upstream_oauth2:
      providers:
        - id: 01JDNFKANIDM00000000000000
          client_secret: ${config.sops.placeholder.${secret}}
  '';
};
systemd.services.matrix-authentication-service.serviceConfig.LoadCredential =
  [ "secrets.yml:${config.sops.templates.mas-secrets.path}" ];
```

Nouveaux secrets consumer (`usr/secrets`) :

| Secret | Génération |
|---|---|
| `mas-encryption-secret` | `openssl rand -hex 32` |
| `mas-rsa-private-key` | `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096` |
| `mas-synapse-secret` | `openssl rand -hex 32` |

`oidc-secret-matrix` (Kanidm) est réutilisé tel quel.

NB : la fusion YAML de MAS entre fichiers `--config` est récursive pour les
maps ; vérifier le comportement pour la **liste** `upstream_oauth2.providers`
(sinon : déclarer le provider entier uniquement dans `secrets.yml`, et rien
dans `settings` — le module nixpkgs élague déjà `upstream_oauth2 == {}`).

### Synapse (bloc conditionnel `mas.enable`)

```nix
services.matrix-synapse.settings = {
  matrix_authentication_service = {
    enabled = true;
    endpoint = "http://localhost:${toString masPort}/";
    secret_path = <sops mas-synapse-secret>;
  };
  # MSC4190 : devices d'appservice sans /login (requis par les bridges)
  experimental_features.msc4190_enabled = true;
};
```

Et **retirer** quand MAS est actif (incompatibles / ignorés) :
`oidc_providers`, `enable_registration`, `registration_requires_token`,
`registration_shared_secret_path`. Le template Kanidm
`darkone.service.idm.oauth2.matrix` change de `redirectPaths` :
`[ "/_synapse/client/oidc/callback" ]` → `[ "/upstream/callback/<ULID>" ]`.

### Bridges

Avec MAS, `/login` d'appservice n'existe plus : les bridges gèrent leurs
devices E2BE via MSC4190.

- bridgev2 (whatsapp, signal, meta) : `encryption.msc4190 = true;` (telegram
  l'a déjà via `bridge.encryption.msc4190`).
- Tout le reste est inchangé : `as_token`/`hs_token` restent vérifiés
  localement par Synapse, le double puppeting appservice (`doublepuppet`)
  fonctionne tel quel, registrations sops déterministes conservées.

### friendRegistration (changement de mécanique)

Les tokens d'inscription ne sont plus mintés par l'admin API Synapse mais
par MAS, sur l'hôte :

```sh
mas-cli manage issue-user-registration-token --usage-limit 1 --expires-in 604800
```

Admin : `mas-cli manage promote-admin <user>` (les tokens compat n'ont pas
le scope `urn:synapse:admin:*` → Synapse-Admin UI perd l'accès admin ; la
gestion utilisateurs bascule sur `mas-cli` + portail `/account`).

## Ce qui ne change pas (transparence)

- coturn/VoIP, metrics Prometheus, Element Web (découverte auto), fédération.
- Comptes amis : login mot de passe OK (couche compat MAS).
- Bot alertmanager : son access token statique est importé par syn2mas
  (sessions compat migrées) ; renouvellement futur via
  `mas-cli manage issue-compatibility-token <user>`.
- `.well-known` servis par Caddy : inchangés.

## Migration d'une instance existante (syn2mas)

Downtime obligatoire, **non réversible facilement** → backup postgres avant
(pg_dump `postgresqlBackup` déjà actif).

1. Déployer avec `mas.enable = true` : MAS démarre (DB migrée, provider
   sync), Synapse déjà en mode délégué — fenêtre de maintenance requise.
2. `systemctl stop matrix-synapse matrix-authentication-service`.
3. Ajouter au config MAS les schemes de mots de passe Synapse (comptes
   amis) : bcrypt `version: 1, unicode_normalization: true` + argon2id
   `version: 2` (upgrade au prochain login). À intégrer d'office dans le
   module : inoffensif pour une install neuve.
4. `mas-cli syn2mas check`, puis `migrate --dry-run`, puis réel
   (le `synapse_idp_id: "oidc-kanidm"` mappe les users OIDC existants).
5. Redémarrer. Vérifier login OIDC, login ami, bridges, bot alertes.

Install neuve : étapes 2–4 inutiles, aucune action manuelle hors secrets.

## Phasage

1. **P1** : port `matrixAuth`, option `mas.enable` (défaut false), bloc MAS
   complet (service, secrets, synapse, kanidm, proxy, bridges msc4190).
2. **P2** : doc utilisateur (secrets, mint tokens amis, promote-admin) ;
   validation manuelle en VM (pas de scénario `server-matrix` existant —
   à envisager séparément).
3. **P3** : migration syn2mas de la prod (fenêtre de maintenance).
4. **P4** : `mas.enable = true` par défaut ; retrait du chemin
   `oidc_providers` legacy.

Estimation : ~150 lignes dans `matrix.nix` + 1 port + doc.

## Références

- Module nixpkgs : `nixos/modules/services/matrix/matrix-authentication-service.nix`
- <https://element-hq.github.io/matrix-authentication-service/> (setup
  homeserver, reverse-proxy, migration syn2mas, référence config)
- Synapse `matrix_authentication_service` :
  <https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#matrix_authentication_service>
- MSC4190 (devices appservice) : <https://github.com/matrix-org/matrix-spec-proposals/pull/4190>
- E2BE mautrix + msc4190 : <https://docs.mau.fi/bridges/general/end-to-bridge-encryption.html>
