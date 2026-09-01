# Unit tests for dnf/lib/secrets.nix (internal secrets registry).

{ dnfLib, lib }:
let
  inherit (dnfLib)
    classifySecret
    mkSecretPlan
    secretBundles
    secretGenerators
    secretRules
    ;

  # Plan built from a representative slice of the fleet: a bundle, a couple of
  # plain generators, an external secret and an unknown one.
  plan = mkSecretPlan [
    "turn-secret"
    "kanidm-tls-key"
    "smtp/password"
    "kanidm-tls-chain"
    "restic/gw-ag/rest-password"
    "who-knows-what"
    "turn-secret"
  ];
in
{

  #----------------------------------------------------------------------------
  # Registry integrity
  #----------------------------------------------------------------------------

  # A rule pointing at a generator the shell script does not implement would
  # only blow up at install time.
  testRulesUseKnownGenerators = {
    expr = lib.unique (
      map (r: r.gen) (lib.filter (r: !(lib.elem r.gen (secretGenerators ++ [ "external" ]))) secretRules)
    );
    expected = [ ];
  };

  testBundlesAreGenerators = {
    expr = lib.filter (g: !(lib.elem g secretGenerators)) secretBundles;
    expected = [ ];
  };

  #----------------------------------------------------------------------------
  # classifySecret
  #----------------------------------------------------------------------------

  testClassifyOidcClient = {
    expr = classifySecret "oidc-secret-nextcloud-cloud";
    expected = "hex32";
  };

  testClassifyResticPerHost = {
    expr = classifySecret "restic/gw-ag/rest-password";
    expected = "b64";
  };

  testClassifyResticPerZone = {
    expr = classifySecret "restic-password-ag";
    expected = "b64";
  };

  # `mas-rsa-private-key` must win over the broader `mas-.*-secret` family.
  testClassifyMasRsaKey = {
    expr = classifySecret "mas-rsa-private-key";
    expected = "rsa4096";
  };

  testClassifyMasSharedSecret = {
    expr = classifySecret "mas-synapse-secret";
    expected = "hex32";
  };

  # Telegram issues these; the generic `mautrix-.*` rule must not catch them.
  testClassifyTelegramApiIsExternal = {
    expr = classifySecret "mautrix-telegram-api-hash";
    expected = "external";
  };

  testClassifyBridgeTokenIsGenerated = {
    expr = classifySecret "mautrix-telegram-as-token";
    expected = "hex32";
  };

  # Pre-filling it would make `just configure-alert-bot` skip the account
  # registration it must perform.
  testClassifyAlertBotTokenIsExternal = {
    expr = classifySecret "alertmanager-matrix-token";
    expected = "external";
  };

  testClassifyAlertWebhookIsGenerated = {
    expr = classifySecret "alertmanager-webhook-secret";
    expected = "hex32";
  };

  testClassifyUserHashIsExternal = {
    expr = classifySecret "user/alice/password-hash";
    expected = "external";
  };

  testClassifyLuksIsExternal = {
    expr = classifySecret "luks/gw-ag/passphrase";
    expected = "external";
  };

  testClassifyLuksInitrdKeyIsExternal = {
    expr = classifySecret "luks/gw-ag/initrd-key";
    expected = "external";
  };

  testClassifyLuksInitrdPubKeyIsExternal = {
    expr = classifySecret "luks/gw-ag/initrd-key-pub";
    expected = "external";
  };

  testClassifyYubikeyIsExternal = {
    expr = classifySecret "yubikey/alice/main/luks-secret";
    expected = "external";
  };

  testClassifyUnknown = {
    expr = classifySecret "brand-new-service-secret";
    expected = null;
  };

  #----------------------------------------------------------------------------
  # mkSecretPlan
  #----------------------------------------------------------------------------

  # Deduplicated, sorted, one unit per value; the x509 pair travels as a
  # single unit so the certificate and its key are always born together.
  testPlanGenerate = {
    expr = plan.generate;
    expected = [
      {
        gen = "b64";
        keys = [ "restic/gw-ag/rest-password" ];
      }
      {
        gen = "hex32";
        keys = [ "turn-secret" ];
      }
      {
        gen = "x509";
        keys = [
          "kanidm-tls-chain"
          "kanidm-tls-key"
        ];
      }
    ];
  };

  testPlanManual = {
    expr = plan.manual;
    expected = [ "smtp/password" ];
  };

  testPlanUnknown = {
    expr = plan.unknown;
    expected = [ "who-knows-what" ];
  };

  testPlanEmpty = {
    expr = mkSecretPlan [ ];
    expected = {
      generate = [ ];
      manual = [ ];
      unknown = [ ];
    };
  };
}
