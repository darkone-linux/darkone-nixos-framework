# Tests for dnf/lib/homepage.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  inherit (dnfLib) constants;
in
{

  # ----- mkHomepageSection -----
  # Global service in the www zone → green
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

  # Global service outside www zone → yellow
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

  # Local private service → blue
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

  # Remote private service → orange
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

  # "(zone:host)" mention injected
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
