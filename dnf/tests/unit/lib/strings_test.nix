# Tests for dnf/lib/strings.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
{
  testUcFirst = {
    expr = dnfLib.ucFirst "hello";
    expected = "Hello";
  };
  testUcFirstSingle = {
    expr = dnfLib.ucFirst "a";
    expected = "A";
  };
  testUcFirstEmpty = {
    expr = dnfLib.ucFirst "";
    expected = "";
  };
  testCleanNewlines = {
    expr = dnfLib.cleanString "hello\n\n\n\nworld";
    expected = "hello\n\nworld";
  };
  testCleanClean = {
    expr = dnfLib.cleanString "no consecutive newlines here";
    expected = "no consecutive newlines here";
  };

  # ----- mkCaddySecurityHeaders -----
  # Sans upload size : pas de bloc `request_body`
  testCaddyHeadersNoUpload = {
    expr =
      let
        out = dnfLib.mkCaddySecurityHeaders { };
      in
      {
        hasFrameOptions = builtins.match ".*X-Frame-Options.*" out != null;
        hasHsts = builtins.match ".*Strict-Transport-Security.*" out != null;
        hasEncode = builtins.match ".*encode gzip.*" out != null;
        hasRequestBody = builtins.match ".*request_body.*" out != null;
      };
    expected = {
      hasFrameOptions = true;
      hasHsts = true;
      hasEncode = true;
      hasRequestBody = false;
    };
  };

  # Avec maxUploadSize : le bloc `request_body` est inséré
  testCaddyHeadersWithUpload = {
    expr =
      let
        out = dnfLib.mkCaddySecurityHeaders { maxUploadSize = "4GB"; };
      in
      {
        hasRequestBody = builtins.match ".*request_body.*" out != null;
        hasSize = builtins.match ".*max_size 4GB.*" out != null;
      };
    expected = {
      hasRequestBody = true;
      hasSize = true;
    };
  };

  # extraHeaders est injecté dans le bloc `header { ... }`
  testCaddyHeadersExtraHeaders = {
    expr =
      let
        out = dnfLib.mkCaddySecurityHeaders { extraHeaders = ''X-Content-Type-Options "nosniff"''; };
      in
      builtins.match ".*X-Content-Type-Options.*" out != null;
    expected = true;
  };
}
