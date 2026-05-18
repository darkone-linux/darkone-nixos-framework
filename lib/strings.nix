# Strings manipulations

{ lib }:
rec {
  ucFirst =
    str:
    lib.concatStrings [
      (lib.toUpper (lib.substring 0 1 str))
      (lib.substring 1 (-1) str)
    ];

  cleanString =
    s:
    let
      s' = builtins.replaceStrings [ "\n\n\n" ] [ "\n\n" ] s;
    in
    if s' == s then lib.strings.trim s else cleanString s';

  # Caddyfile fragment producing the baseline DNF security headers, a
  # gzip directive and (optionally) a `request_body` upload-size cap.
  # Extra service-specific headers can be appended via `extraHeaders`.
  #
  # Usage:
  #   proxy.extraConfig = dnfLib.mkCaddySecurityHeaders {
  #     maxUploadSize = "4GB";
  #     extraHeaders = ''
  #       X-Content-Type-Options "nosniff"
  #     '';
  #   };
  mkCaddySecurityHeaders =
    {
      maxUploadSize ? null,
      extraHeaders ? "",
    }:
    ''
      header {
        X-Frame-Options "sameorigin"
        X-Robots-Tag "noindex,nofollow"
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        ${extraHeaders}
      }
      ${lib.optionalString (maxUploadSize != null) ''
        request_body {
          max_size ${maxUploadSize}
        }
      ''}
      encode gzip
    '';
}
