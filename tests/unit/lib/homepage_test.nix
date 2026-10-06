# Tests for dnf/lib/homepage.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  inherit (dnfLib) constants;

  # Description of the single entry rendered for a service of `zone`, seen
  # from the `lan` zone.
  describe =
    {
      zone,
      global,
      host ? "somehost",
    }:
    let
      srv = {
        displayOnHomepage = true;
        params = {
          title = "Svc";
          description = "Desc";
          href = "https://svc.example.com";
          icon = "sh-svc";
          inherit zone global host;
        };
      };
    in
    (builtins.head (dnfLib.mkHomepageSection "lan" [ srv ])).Svc.content.description;
  hasMarker = marker: description: builtins.match ".*${marker}.*" description != null;
in
{

  # ----- mkHomepageSection -----

  # Global service in the global zone → green
  testMkHomepageSectionPublicGlobal = {
    expr = hasMarker "🟢" (describe {
      zone = constants.globalZone;
      global = true;
    });
    expected = true;
  };

  # Global service outside the global zone → yellow
  testMkHomepageSectionPublicNonGlobal = {
    expr = hasMarker "🟡" (describe {
      zone = "dmz";
      global = true;
    });
    expected = true;
  };

  # Private service of the current zone → blue
  testMkHomepageSectionPrivateLocal = {
    expr = hasMarker "🔵" (describe {
      zone = "lan";
      global = false;
    });
    expected = true;
  };

  # Private service of another zone → orange
  testMkHomepageSectionPrivateRemote = {
    expr = hasMarker "🟠" (describe {
      zone = "dmz";
      global = false;
    });
    expected = true;
  };

  # Full description: text, `(zone:host)` mention, marker
  testMkHomepageSectionMention = {
    expr = describe {
      zone = "lan";
      global = false;
      host = "testhost";
    };
    expected = "Desc (lan:testhost) 🔵";
  };

  # `displayOnHomepage = false` keeps the entry, disabled by `mkIf`
  testMkHomepageSectionHidden = {
    expr =
      (builtins.head (
        dnfLib.mkHomepageSection "lan" [
          {
            displayOnHomepage = false;
            params = {
              title = "Svc";
              description = "Desc";
              href = "x";
              icon = "y";
              zone = "lan";
              global = false;
              host = "h";
            };
          }
        ]
      )).Svc.condition;
    expected = false;
  };
}
