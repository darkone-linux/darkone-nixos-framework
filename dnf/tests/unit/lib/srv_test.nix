# Tests for dnf/lib/srv.nix
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

  mockZone = {
    name = "lan";
    gateway.hostname = "testhost";
  };

  mockGlobalZone = {
    name = constants.globalZone;
    gateway.hostname = "hcshost";
  };

  hcsHost = {
    hostname = "hcshost";
    zone = constants.globalZone;
    networkDomain = "example.com";
    zoneDomain = "example.com";
    ip = "203.0.113.1";
  };

  vpnHost = mockHost // {
    hostname = "vpnhost";
    vpnIp = "100.64.1.5";
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
  # ----- isVpnClient -----
  testIsVpnClientTrue = {
    expr = dnfLib.isVpnClient { vpnIp = "100.64.1.1"; };
    expected = true;
  };
  testIsVpnClientFalseMissing = {
    expr = dnfLib.isVpnClient { hostname = "testhost"; };
    expected = false;
  };
  testIsVpnClientFalseEmpty = {
    expr = dnfLib.isVpnClient { vpnIp = ""; };
    expected = false;
  };

  # ----- inLocalZone -----
  testInLocalZoneTrue = {
    expr = dnfLib.inLocalZone { name = "lan"; };
    expected = true;
  };
  testInLocalZoneFalse = {
    expr = dnfLib.inLocalZone { name = constants.globalZone; };
    expected = false;
  };

  # ----- isGateway -----
  testIsGatewayTrue = {
    expr = dnfLib.isGateway mockHost mockZone;
    expected = true;
  };
  testIsGatewayFalseNotGateway = {
    expr = dnfLib.isGateway (mockHost // { hostname = "otherhost"; }) mockZone;
    expected = false;
  };
  testIsGatewayFalseVpnClient = {
    expr = dnfLib.isGateway (mockHost // { vpnIp = "100.64.1.1"; }) mockZone;
    expected = false;
  };

  # ----- isHcs -----
  testIsHcsTrue = {
    expr = dnfLib.isHcs hcsHost mockGlobalZone mockNetworkHcs;
    expected = true;
  };
  testIsHcsFalseLocalZone = {
    expr = dnfLib.isHcs hcsHost mockZone mockNetworkHcs;
    expected = false;
  };
  testIsHcsFalseNoCoordination = {
    expr = dnfLib.isHcs hcsHost mockGlobalZone (mockNetworkHcs // { coordination.enable = false; });
    expected = false;
  };

  # ----- getInternalInterfaceFwPath -----
  testFwPathGateway = {
    expr = dnfLib.getInternalInterfaceFwPath mockHost mockZone;
    expected = [
      "interfaces"
      constants.lanInterface
    ];
  };
  testFwPathVpnClient = {
    expr = dnfLib.getInternalInterfaceFwPath (mockHost // { vpnIp = "100.64.1.1"; }) mockZone;
    expected = [
      "interfaces"
      constants.vpnInterface
    ];
  };
  testFwPathRegularHost = {
    expr = dnfLib.getInternalInterfaceFwPath (mockHost // { hostname = "otherhost"; }) mockZone;
    expected = [ ];
  };
  # Régression : vpnIp vide ne doit pas être classé comme client VPN
  testFwPathVpnEmptyIp = {
    expr = dnfLib.getInternalInterfaceFwPath (
      mockHost
      // {
        hostname = "otherhost";
        vpnIp = "";
      }
    ) mockZone;
    expected = [ ];
  };

  # ----- findHost -----
  testFindHostFound = {
    expr = (dnfLib.findHost "testhost" "lan" mockHosts).hostname;
    expected = "testhost";
  };
  testFindHostMissing = {
    expr = dnfLib.findHost "ghost" "lan" mockHosts;
    expected = { };
  };

  # ----- findService -----
  testFindServiceFound = {
    expr = (dnfLib.findService "wiki" "lan" mockServices).host;
    expected = "testhost";
  };
  testFindServiceMissing = {
    expr = dnfLib.findService "ghost" "lan" mockServices;
    expected = null;
  };

  # ----- buildServiceParams : service local, defaults complets -----
  testBuildServiceParamsLocal = {
    expr =
      let
        p = dnfLib.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } { };
      in
      {
        inherit (p)
          domain
          title
          icon
          fqdn
          href
          ip
          global
          ;
      };
    expected = {
      domain = "wiki";
      title = "Wiki";
      icon = "sh-wiki";
      fqdn = "wiki.lan.example.com";
      href = "http://wiki.lan.example.com";
      ip = "192.168.1.10";
      global = false;
    };
  };

  # ----- buildServiceParams : cascade vers defaults -----
  testBuildServiceParamsCascadeDefaults = {
    expr =
      let
        p = dnfLib.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } {
          domain = "knowledge";
          title = "Knowledge Base";
          description = "Internal docs";
        };
      in
      {
        inherit (p) domain title description;
      };
    expected = {
      domain = "knowledge";
      title = "Knowledge Base";
      description = "Internal docs";
    };
  };

  # ----- buildServiceParams : service global utilise networkDomain -----
  testBuildServiceParamsGlobalFqdn = {
    expr =
      let
        p = dnfLib.buildServiceParams hcsHost mockNetworkHcs {
          name = "site";
          global = true;
        } { };
      in
      {
        inherit (p) fqdn href global;
      };
    expected = {
      fqdn = "site.example.com";
      href = "https://site.example.com";
      global = true;
    };
  };

  # ----- buildServiceParams : HCS résout sur loopback -----
  testBuildServiceParamsHcsLoopback = {
    expr = (dnfLib.buildServiceParams hcsHost mockNetworkHcs { name = "auth"; } { }).ip;
    expected = "127.0.0.1";
  };

  # ----- buildServiceParams : client VPN avec vpnIp -----
  testBuildServiceParamsVpnIp = {
    expr = (dnfLib.buildServiceParams vpnHost mockNetworkHcs { name = "remote"; } { }).ip;
    expected = "100.64.1.5";
  };

  # ----- buildServiceParams : vpnIp vide retombe sur host.ip -----
  testBuildServiceParamsEmptyVpnIp = {
    expr =
      (dnfLib.buildServiceParams (mockHost // { vpnIp = ""; }) mockNetworkPlain { name = "svc"; } { }).ip;
    expected = "192.168.1.10";
  };

  # ----- extractServiceParams : service trouvé -----
  testExtractServiceParamsFound = {
    expr =
      let
        net = mockNetworkPlain // {
          services = mockServices;
        };
        p = dnfLib.extractServiceParams mockHost net "wiki" { description = "default desc"; };
      in
      {
        inherit (p) domain zone host;
      };
    expected = {
      domain = "wiki";
      zone = "lan";
      host = "testhost";
    };
  };

  # ----- extractServiceParams : service inexistant retombe sur defaults -----
  testExtractServiceParamsMissing = {
    expr =
      let
        net = mockNetworkPlain // {
          services = mockServices;
        };
        p = dnfLib.extractServiceParams mockHost net "ghost" { domain = "ghosts"; };
      in
      {
        inherit (p) domain zone;
      };
    expected = {
      domain = "ghosts";
      zone = "lan";
    };
  };

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
  # clientName explicitement null → règle par défaut
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

  # ----- preferredIp -----
  testPreferredIpVpn = {
    expr = dnfLib.preferredIp {
      vpnIp = "100.64.1.5";
      ip = "192.168.1.10";
    };
    expected = "100.64.1.5";
  };
  testPreferredIpFallbackLan = {
    expr = dnfLib.preferredIp {
      vpnIp = "";
      ip = "192.168.1.10";
    };
    expected = "192.168.1.10";
  };
  testPreferredIpNoVpnAttr = {
    expr = dnfLib.preferredIp { ip = "10.0.0.5"; };
    expected = "10.0.0.5";
  };
  testPreferredIpLoopback = {
    expr = dnfLib.preferredIp { };
    expected = "127.0.0.1";
  };

  # ----- mkInternalFirewall -----
  # Hôte non-gateway, non-VPN : path racine, ports actifs (mkIf true)
  testMkInternalFirewallRegular = {
    expr =
      let
        fw = dnfLib.mkInternalFirewall (mockHost // { hostname = "otherhost"; }) mockZone [ 3000 ];
        v = fw.allowedTCPPorts;
      in
      {
        inherit (v) _type condition content;
      };
    expected = {
      _type = "if";
      condition = true;
      content = [ 3000 ];
    };
  };
  # Gateway : path = [interfaces lan0], ports désactivés (mkIf false)
  # On introspecte la structure `mkIf` produite sans dépendre de `lib`.
  testMkInternalFirewallGateway = {
    expr =
      let
        fw = dnfLib.mkInternalFirewall mockHost mockZone [ 3000 ];
        v = fw.interfaces.${constants.lanInterface}.allowedTCPPorts;
      in
      {
        inherit (v) _type condition content;
      };
    expected = {
      _type = "if";
      condition = false;
      content = [ 3000 ];
    };
  };
  # Client VPN : path = [interfaces tailscale0]
  testMkInternalFirewallVpn = {
    expr =
      let
        h = mockHost // {
          hostname = "vpnhost";
          vpnIp = "100.64.1.5";
        };
        fw = dnfLib.mkInternalFirewall h mockZone [ 8080 ];
        v = fw.interfaces.${constants.vpnInterface}.allowedTCPPorts;
      in
      {
        inherit (v) _type condition content;
      };
    expected = {
      _type = "if";
      condition = true;
      content = [ 8080 ];
    };
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
  # Multi-instance (cas monitoring) : deux entrées partageant le même
  # clientId doivent fusionner en UN seul client avec les deux redirect
  # URIs distincts.
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

  # ClientIds distincts (sous-domaines différents) restent séparés : pas
  # de fusion intempestive entre services indépendants.
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

  # Les URIs déjà absolues (schémas mobiles ex. app.immich:///) doivent
  # être passées telles quelles, sans préfixage par href.
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

  # ----- enableBlock -----
  testEnableBlock = {
    expr = dnfLib.enableBlock "forgejo";
    expected = {
      enable = true;
      service.forgejo.enable = true;
    };
  };

  # ----- mkHomepageSection -----
  # Service global dans la zone www → vert
  testMkHomepageSectionPublicGlobal = {
    expr =
      let
        srv = {
          displayOnHomepage = true;
          params = {
            title = "Site";
            description = "Public";
            href = "https://site.example.com";
            icon = "sh-site";
            global = true;
            zone = constants.globalZone;
            host = "hcshost";
          };
        };
        out = builtins.head (dnfLib.mkHomepageSection "lan" [ srv ]);
      in
      builtins.match ".*🟢.*" out.Site.content.description != null;
    expected = true;
  };
  # Service global hors zone www → jaune
  testMkHomepageSectionPublicNonGlobal = {
    expr =
      let
        srv = {
          displayOnHomepage = true;
          params = {
            title = "Site";
            description = "Public";
            href = "https://site.example.com";
            icon = "sh-site";
            global = true;
            zone = "dmz";
            host = "host";
          };
        };
        out = builtins.head (dnfLib.mkHomepageSection "lan" [ srv ]);
      in
      builtins.match ".*🟡.*" out.Site.content.description != null;
    expected = true;
  };
  # Service privé local → bleu
  testMkHomepageSectionPrivateLocal = {
    expr =
      let
        srv = {
          displayOnHomepage = true;
          params = {
            title = "Wiki";
            description = "Internal";
            href = "http://wiki.lan";
            icon = "sh-wiki";
            global = false;
            zone = "lan";
            host = "testhost";
          };
        };
        out = builtins.head (dnfLib.mkHomepageSection "lan" [ srv ]);
      in
      builtins.match ".*🔵.*" out.Wiki.content.description != null;
    expected = true;
  };
  # Service privé distant → orange
  testMkHomepageSectionPrivateRemote = {
    expr =
      let
        srv = {
          displayOnHomepage = true;
          params = {
            title = "Wiki";
            description = "Internal";
            href = "http://wiki.dmz";
            icon = "sh-wiki";
            global = false;
            zone = "dmz";
            host = "otherhost";
          };
        };
        out = builtins.head (dnfLib.mkHomepageSection "lan" [ srv ]);
      in
      builtins.match ".*🟠.*" out.Wiki.content.description != null;
    expected = true;
  };
  # Mention "(zone:host)" injectée
  testMkHomepageSectionMention = {
    expr =
      let
        srv = {
          displayOnHomepage = true;
          params = {
            title = "Svc";
            description = "Desc";
            href = "x";
            icon = "y";
            global = false;
            zone = "lan";
            host = "testhost";
          };
        };
        out = builtins.head (dnfLib.mkHomepageSection "lan" [ srv ]);
      in
      builtins.match ".*\\(lan:testhost\\).*" out.Svc.content.description != null;
    expected = true;
  };
}
