# Tests for dnf/lib/matrix.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib, lib }:
let
  withoutRtc = dnfLib.mkMatrixWellKnown { domain = "example.org"; };
  withRtc = dnfLib.mkMatrixWellKnown {
    domain = "example.org";
    rtcFociUrl = "https://matrix.example.org/livekit/jwt";
  };

  # The generated fragment is a Caddyfile, so assertions match on substrings.
  has = needle: haystack: lib.hasInfix needle haystack;
in
{

  # ----- mkMatrixWellKnown: homeserver discovery -----

  # Both documents are always served, and the base_url points at the matrix
  # subdomain rather than the apex (which only hosts the well-known).
  testServesClientDocument = {
    expr = has ''{"m.homeserver":{"base_url":"https://matrix.example.org"}}'' withoutRtc;
    expected = true;
  };
  testServesServerDocument = {
    expr = has ''{"m.server":"matrix.example.org:443"}'' withRtc;
    expected = true;
  };

  # ----- mkMatrixWellKnown: MatrixRTC focus (MSC4143) -----

  # Announced verbatim so Element Call can reach the JWT service.
  testAnnouncesRtcFocus = {
    expr = has ''"org.matrix.msc4143.rtc_foci":[{"livekit_service_url":"https://matrix.example.org/livekit/jwt","type":"livekit"}]'' withRtc;
    expected = true;
  };

  # No LiveKit backend => the key must be absent, not an empty list: clients
  # read an empty list as a configured-but-broken focus.
  testOmitsRtcFocusByDefault = {
    expr = has "msc4143" withoutRtc;
    expected = false;
  };

  # CORS is required on both documents: clients fetch them cross-origin.
  testAllowsCrossOrigin = {
    expr = builtins.length (
      builtins.filter (l: lib.hasInfix "Access-Control-Allow-Origin" l) (lib.splitString "\n" withRtc)
    );
    expected = 2;
  };
}
