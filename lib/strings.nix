# Strings manipulations

{ lib }: rec {
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

  # Country code from a `xx_YY.UTF-8` locale: `"fr_FR.UTF-8"` -> `"FR"`.
  # Returns `null` when the input does not match that exact shape, so callers
  # can assert or fall back rather than crash on a malformed locale.
  #
  # Usage:
  #   extractCountryFromLocale "fr_FR.UTF-8" => "FR"
  extractCountryFromLocale =
    locale:
    let
      parts = builtins.match "^[a-z]{2}_([A-Z]{2})\\.UTF-8$" locale;
    in
    if parts == null then null else builtins.head parts;

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
