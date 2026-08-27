# DNF — internal secrets registry.
#
# Classifies every sops entry the framework can declare into either:
#
# - a **generator id**, when DNF can invent the value on its own: nothing
#   outside the fleet issues it and no human ever has to read it;
# - `"external"`, when the value comes from a human, a piece of hardware or a
#   third party (SMTP provider, Telegram, headscale, a LUKS passphrase typed at
#   boot) and must therefore never be invented.
#
# The registry holds *how to produce* a secret, never *which* secrets exist:
# the authority for that is each host's `sops.secrets`, collected by the
# `secretsPlan` flake output (cf. `lib/mk-configuration.nix`) and fed to
# `mkSecretPlan`. Generator ids are implemented by
# `assets/scripts/just-generate-secrets.sh`, run by `just configure-admin-host`.
#
# :::caution[Declaring a new sops secret in a module]
# A `sops.secrets.<name>` matching no rule below is reported as unknown on
# every `just configure-admin-host`. Add a rule here — with `gen = "external"`
# when the value cannot be invented.
# :::

{ lib }:
let
  inherit (lib)
    elem
    filter
    findFirst
    groupBy
    mapAttrsToList
    sort
    unique
    ;
in
rec {

  # Generator ids the shell side knows how to run. Kept as data so a typo in a
  # rule below is caught by the unit tests instead of at install time.
  #
  # - `hex16` / `hex32` : `openssl rand -hex <n>`
  # - `b64`             : `openssl rand -base64 24` (account-style passwords)
  # - `b64url32`        : 32 URL-safe base64 bytes (oauth2-proxy cookie key)
  # - `s3-key-id`       : `GK` + 12 hex bytes (Garage access-key format)
  # - `rsa4096`         : PKCS#8 RSA private key
  # - `x509`            : self-signed certificate + its key (see `secretBundles`)
  secretGenerators = [
    "b64"
    "b64url32"
    "hex16"
    "hex32"
    "rsa4096"
    "s3-key-id"
    "x509"
  ];

  # Generators emitting SEVERAL sops entries at once: a certificate and its
  # private key are born together or they simply do not match. Their entries
  # are grouped into a single generation unit, produced only when every member
  # is missing (a half-present pair is left untouched and reported).
  secretBundles = [ "x509" ];

  # Ordered classification rules, first match wins. Patterns are full-string
  # regexes (`builtins.match`), so a narrow rule MUST precede the broad family
  # rule it carves an exception out of (`mautrix-telegram-api-*` before
  # `mautrix-*`, `mas-rsa-private-key` before `mas-*-secret`).
  secretRules = [

    #--------------------------------------------------------------------------
    # Generated: OIDC / forward-auth
    #--------------------------------------------------------------------------

    # One Kanidm OAuth2 client secret per provisioned client, plus the shared
    # `internal` client used by oauth2-proxy. Hex keeps them free of characters
    # needing URL or basic-auth escaping.
    {
      pattern = "oidc-secret-.*";
      gen = "hex32";
    }

    # oauth2-proxy validates the cookie key AFTER base64-decoding it: it must
    # weigh exactly 16, 24 or 32 bytes.
    {
      pattern = "oauth2-proxy-cookie-.*";
      gen = "b64url32";
    }

    #--------------------------------------------------------------------------
    # Generated: Matrix (synapse, MAS, MatrixRTC, bridges)
    #--------------------------------------------------------------------------

    # Issued by Telegram (my.telegram.org), not by the fleet.
    {
      pattern = "mautrix-telegram-api-(id|hash)";
      gen = "external";
    }

    # Appservice tokens + per-bridge olm pickle keys.
    {
      pattern = "mautrix-.*";
      gen = "hex32";
    }

    # MAS OIDC token signing key.
    {
      pattern = "mas-rsa-private-key";
      gen = "rsa4096";
    }
    {
      pattern = "mas-.*-secret";
      gen = "hex32";
    }
    {
      pattern = "livekit-secret";
      gen = "hex32";
    }

    # Synapse registration shared secret.
    {
      pattern = "matrix-rss-password";
      gen = "hex32";
    }
    {
      pattern = "matrix-db-password";
      gen = "b64";
    }
    {
      pattern = "turn-secret";
      gen = "hex32";
    }

    #--------------------------------------------------------------------------
    # Generated: alerting
    #--------------------------------------------------------------------------

    # Bot account credentials: created against the live homeserver by
    # `just configure-alert-bot`, which keys its idempotence on their absence.
    # Pre-filling them would make it skip the registration it must perform.
    {
      pattern = "alertmanager-matrix-(token|password)";
      gen = "external";
    }
    {
      pattern = "alertmanager-webhook-secret";
      gen = "hex32";
    }

    #--------------------------------------------------------------------------
    # Generated: identity manager
    #--------------------------------------------------------------------------

    # Kanidm break-glass accounts: machine-generated, read back with `just sops`
    # on the rare occasions the admin needs them.
    {
      pattern = "kanidm-(admin|idm-admin)-password";
      gen = "b64";
    }

    # Kanidm's internal HTTPS listener. Caddy fronts it with
    # `tls_insecure_skip_verify`, so a long-lived self-signed pair is enough.
    {
      pattern = "kanidm-tls-(chain|key)";
      gen = "x509";
    }

    #--------------------------------------------------------------------------
    # Generated: storage & object stores
    #--------------------------------------------------------------------------

    {
      pattern = "garage-rpc-secret";
      gen = "hex32";
    }

    # S3 credentials imported into Garage by its provisioning unit, hence the
    # `GK…` access-key format Garage expects.
    {
      pattern = "garage-.*-key-id";
      gen = "s3-key-id";
    }
    {
      pattern = "garage-.*-key-secret";
      gen = "hex32";
    }
    {
      pattern = "minio-root-user";
      gen = "hex16";
    }
    {
      pattern = "minio-root-password";
      gen = "b64";
    }

    #--------------------------------------------------------------------------
    # Generated: backups
    #--------------------------------------------------------------------------

    # One repository passphrase per zone, one REST credential per fleet host.
    {
      pattern = "restic-password-.*";
      gen = "b64";
    }
    {
      pattern = "restic/[^/]+/rest-password";
      gen = "b64";
    }

    #--------------------------------------------------------------------------
    # Generated: per-service internals
    #--------------------------------------------------------------------------

    # Reachable only through `/login?direct=1` once SSO redirect is on.
    {
      pattern = "nextcloud-admin-password";
      gen = "b64";
    }
    {
      pattern = "nextcloud-whiteboard-secret";
      gen = "hex32";
    }
    {
      pattern = "docs-django-secret-key";
      gen = "hex32";
    }
    {
      pattern = "grafana-secret-key";
      gen = "hex32";
    }
    {
      pattern = "searx-secret-key";
      gen = "hex32";
    }

    # Plain token (not an Argon2 hash): the admin types it on `/admin`, so it
    # has to stay readable from sops.
    {
      pattern = "vaultwarden-admin-token";
      gen = "hex32";
    }

    #--------------------------------------------------------------------------
    # External: chosen by a human
    #--------------------------------------------------------------------------

    # Interactive by design (`just passwd-default`, `just passwd <user>`):
    # a hash the admin cannot type back is worthless.
    {
      pattern = "default-password(-hash)?";
      gen = "external";
    }
    {
      pattern = "user/[^/]+/password-hash";
      gen = "external";
    }

    # Handed out to genealogy visitors, so the admin picks them.
    {
      pattern = "geneweb-(friend|wizard)";
      gen = "external";
    }

    #--------------------------------------------------------------------------
    # External: issued by a third party
    #--------------------------------------------------------------------------

    {
      pattern = "smtp/.*";
      gen = "external";
    }
    {
      pattern = "wifi-password-.*";
      gen = "external";
    }

    # Pre-auth key minted by headscale.
    {
      pattern = "tailscale/.*";
      gen = "external";
    }

    #--------------------------------------------------------------------------
    # External: bound to state living outside sops
    #--------------------------------------------------------------------------

    # Typed at boot and enrolled in a real LUKS keyslot by `just luks`; an
    # invented value would lock the disk out of its own passphrase.
    {
      pattern = "luks-passphrase";
      gen = "external";
    }
    {
      pattern = "luks/[^/]+/passphrase";
      gen = "external";
    }

    # Derived from the physical key by `just yubikey`.
    {
      pattern = "yubikey/.*";
      gen = "external";
    }

    # Half of a keypair whose public side is committed; generated by
    # `just configure-admin-host` itself, next to `usr/secrets/harmonia.pub`.
    {
      pattern = "harmonia-secret-key";
      gen = "external";
    }
  ];

  # Generator id for one sops key, or `null` when no rule matches it.
  classifySecret =
    key:
    let
      rule = findFirst (r: builtins.match r.pattern key != null) null secretRules;
    in
    if rule == null then null else rule.gen;

  # Turn the sops keys a fleet declares into a generation plan:
  #
  # - `generate`: one unit per value to create, `{ gen, keys }`. A bundle
  #   generator yields a single unit holding all of its keys;
  # - `manual`  : keys DNF must never invent;
  # - `unknown` : keys matching no rule — a module declares a secret the
  #   registry has not been taught about yet.
  #
  # Sorted and deduplicated: the plan is consumed by a shell script whose
  # output must not depend on evaluation order.
  mkSecretPlan =
    keys:
    let
      classified = map (key: {
        inherit key;
        gen = classifySecret key;
      }) (sort (a: b: a < b) (unique keys));
      known = filter (c: c.gen != null && c.gen != "external") classified;
      single = filter (c: !(elem c.gen secretBundles)) known;
      grouped = mapAttrsToList (gen: cs: {
        inherit gen;
        keys = map (c: c.key) cs;
      }) (groupBy (c: c.gen) (filter (c: elem c.gen secretBundles) known));
    in
    {
      generate =
        map (c: {
          inherit (c) gen;
          keys = [ c.key ];
        }) single
        ++ grouped;
      manual = map (c: c.key) (filter (c: c.gen == "external") classified);
      unknown = map (c: c.key) (filter (c: c.gen == null) classified);
    };
}
