# Tests for dnf/lib/oidc.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  inherit (dnfLib) constants;

  mockHost = {
    hostname = "testhost";
    zone = "lan";
    networkDomain = "example.com";
    zoneDomain = "lan.example.com";
    ip = "192.168.1.10";
  };

  hcsHost = {
    hostname = "hcshost";
    zone = constants.globalZone;
    networkDomain = "example.com";
    zoneDomain = "example.com";
    ip = "203.0.113.1";
  };

  mockNetworkPlain = {
    coordination.enable = false;
    services = [ ];
  };

  mockNetworkHcs = {
    coordination = {
      enable = true;
      hostname = "hcshost";
    };
    services = [ ];
  };

  mockHosts = [
    mockHost
    (
      mockHost
      // {
        hostname = "otherhost";
        zone = "dmz";
      }
    )
    hcsHost
  ];

  mockServices = [
    {
      name = "wiki";
      host = "testhost";
      zone = "lan";
    }
    {
      name = "wiki";
      host = "otherhost";
      zone = "dmz";
    }
    {
      name = "global-svc";
      host = "hcshost";
      zone = constants.globalZone;
      global = true;
    }
  ];
in
{

  # ----- oauth2ClientName -----
  testOauth2NameDefault = {
    expr = dnfLib.oauth2ClientName { name = "forgejo"; } { domain = "forgejo"; };
    expected = "forgejo";
  };
  testOauth2NameRenamedDomain = {
    expr = dnfLib.oauth2ClientName { name = "outline"; } { domain = "notes"; };
    expected = "outline-notes";
  };
  testOauth2NameOverride = {
    expr = dnfLib.oauth2ClientName {
      name = "matrix";
      clientName = "matrix-synapse";
    } { domain = "matrix"; };
    expected = "matrix-synapse";
  };

  # clientName explicitly null → default rule
  testOauth2NameNullOverride = {
    expr = dnfLib.oauth2ClientName {
      name = "mealie";
      clientName = null;
    } { domain = "mealie"; };
    expected = "mealie";
  };

  # ----- idmHref -----
  testIdmHrefPresent = {
    expr =
      let
        net = mockNetworkHcs // {
          services = [
            {
              name = "idm";
              host = "hcshost";
              zone = constants.globalZone;
              global = true;
            }
          ];
        };
      in
      dnfLib.idmHref net mockHosts;
    expected = "https://idm.example.com";
  };
  testIdmHrefMissing = {
    expr = dnfLib.idmHref (mockNetworkHcs // { services = mockServices; }) mockHosts;
    expected = null;
  };

  # ----- mkOidcContext -----
  testMkOidcContextStandard = {
    expr = dnfLib.mkOidcContext {
      name = "outline";
      params = {
        domain = "outline";
      };
      network = mockNetworkHcs // {
        services = [
          {
            name = "idm";
            host = "hcshost";
            zone = constants.globalZone;
            global = true;
          }
        ];
      };
      hosts = mockHosts;
    };
    expected = {
      clientId = "outline";
      secret = "oidc-secret-outline";
      idmUrl = "https://idm.example.com";
    };
  };
  testMkOidcContextRenamedDomain = {
    expr =
      (dnfLib.mkOidcContext {
        name = "outline";
        params = {
          domain = "notes";
        };
        network = mockNetworkPlain;
        hosts = [ ];
      }).clientId;
    expected = "outline-notes";
  };
  testMkOidcContextClientNameOverride = {
    expr =
      (dnfLib.mkOidcContext {
        name = "matrix";
        clientName = "matrix-synapse";
        params = {
          domain = "matrix";
        };
        network = mockNetworkPlain;
        hosts = [ ];
      }).clientId;
    expected = "matrix-synapse";
  };
  testMkOidcContextNoIdm = {
    expr =
      (dnfLib.mkOidcContext {
        name = "mealie";
        params = {
          domain = "mealie";
        };
        network = mockNetworkPlain;
        hosts = mockHosts;
      }).idmUrl;
    expected = null;
  };

  # ----- mkOauth2Clients -----
  # Multi-instance (monitoring case): two entries sharing the same
  # clientId must merge into ONE client with both distinct redirect URIs.
  testMkOauth2ClientsMergeMultiZone =
    let
      mkPair = href: {
        clientId = "monitoring";
        secret = "oidc-secret-monitoring";
        tpl = {
          redirectPaths = [ "/login/generic_oauth" ];
          landingPath = "/";
        };
        params = { inherit href; };
      };
      result = dnfLib.mkOauth2Clients [
        (mkPair "https://monitoring.ag.example.com")
        (mkPair "https://monitoring.cp.example.com")
      ];
      one = builtins.head result;
    in
    {
      expr = {
        count = builtins.length result;
        inherit (one) clientId originUrls originLanding;
      };
      expected = {
        count = 1;
        clientId = "monitoring";
        originUrls = [
          "https://monitoring.ag.example.com/login/generic_oauth"
          "https://monitoring.cp.example.com/login/generic_oauth"
        ];
        originLanding = "https://monitoring.ag.example.com/";
      };
    };

  # Distinct clientIds (different subdomains) stay separate: no
  # accidental merging between independent services.
  testMkOauth2ClientsDistinctClientsStayApart = {
    expr = builtins.length (
      dnfLib.mkOauth2Clients [
        {
          clientId = "outline-notes";
          secret = "oidc-secret-outline-notes";
          tpl = {
            redirectPaths = [ "/auth/cb" ];
            landingPath = "/";
          };
          params.href = "https://notes.example.com";
        }
        {
          clientId = "outline-kb";
          secret = "oidc-secret-outline-kb";
          tpl = {
            redirectPaths = [ "/auth/cb" ];
            landingPath = "/";
          };
          params.href = "https://kb.example.com";
        }
      ]
    );
    expected = 2;
  };

  # Already absolute URIs (mobile schemes e.g. app.immich:///) must be
  # passed through as-is, without href prefixing.
  testMkOauth2ClientsAbsoluteUriPassthrough = {
    expr =
      (builtins.head (
        dnfLib.mkOauth2Clients [
          {
            clientId = "immich";
            secret = "oidc-secret-immich";
            tpl = {
              redirectPaths = [
                "/auth"
                "app.immich:///oauth-callback"
              ];
              landingPath = "/";
            };
            params.href = "https://photos.example.com";
          }
        ]
      )).originUrls;
    expected = [
      "https://photos.example.com/auth"
      "app.immich:///oauth-callback"
    ];
  };

  # ----- mkKanidmEndpoints -----
  testMkKanidmEndpoints = {
    expr = dnfLib.mkKanidmEndpoints "https://idm.example.com" "outline";
    expected = {
      authUrl = "https://idm.example.com/ui/oauth2";
      tokenUrl = "https://idm.example.com/oauth2/token";
      userinfoUrl = "https://idm.example.com/oauth2/openid/outline/userinfo";
      jwksUrl = "https://idm.example.com/oauth2/openid/outline/public_key.jwk";
      openidConfigUrl = "https://idm.example.com/oauth2/openid/outline/.well-known/openid-configuration";
      issuerUrl = "https://idm.example.com/oauth2/openid/outline";
    };
  };
}
