# Tests for dnf/lib/nix-tools.nix — tooling picked by Nix minor.
#
# Helpers read `version` only: plain attrsets stand in for the packages.
#
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  unstable = {
    version = "2.35.3";
  };
  stable = {
    version = "2.34.3";
  };
  nix = version: { inherit version; };
  pick =
    nixVersion:
    (dnfLib.pickForNix {
      candidates = [
        unstable
        stable
      ];
      nix = nix nixVersion;
    }).version;
in
{

  # pickForNix — the candidate sharing the X.Y of the system Nix wins
  testPickMatchingMinor = {
    expr = pick "2.34.8";
    expected = "2.34.3";
  };
  testPickNewerMinor = {
    expr = pick "2.35.0";
    expected = "2.35.3";
  };

  # No candidate matches: the first one, and the module asserts
  testPickFallsBackToFirst = {
    expr = pick "2.30.1";
    expected = "2.35.3";
  };

  # matchesNix — patch levels are ignored, minors are not
  testMatchesNixSameMinor = {
    expr = dnfLib.matchesNix {
      package = stable;
      nix = nix "2.34.8";
    };
    expected = true;
  };
  testMatchesNixOtherMinor = {
    expr = dnfLib.matchesNix {
      package = unstable;
      nix = nix "2.34.8";
    };
    expected = false;
  };
}
