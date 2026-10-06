# DNF — string helpers
#
# Pure helpers for text and Caddyfile fragments.

{ lib }: rec {

  # `"wiki"` -> `"Wiki"`.
  ucFirst =
    str:
    lib.concatStrings [
      (lib.toUpper (lib.substring 0 1 str))
      (lib.substring 1 (-1) str)
    ];

  # Runs of blank lines collapsed to one, then trimmed: tidies Caddyfile
  # fragments whose optional sections interpolate to nothing.
  cleanString =
    s:
    let
      s' = builtins.replaceStrings [ "\n\n\n" ] [ "\n\n" ] s;
    in
    if s' == s then lib.strings.trim s else cleanString s';

  # Canonical locale shape (`builtins.match`, fully anchored): `xx_YY.UTF-8`,
  # groups language and country.
  localeRegex = "([a-z]{2})_([A-Z]{2})\\.UTF-8";

  # Country code of a canonical locale (`"fr_FR.UTF-8"` -> `"FR"`), `null`
  # when the locale has another shape.
  extractCountryFromLocale =
    locale:
    let
      parts = builtins.match localeRegex locale;
    in
    if parts == null then null else builtins.elemAt parts 1;

  # Caddyfile fragment: baseline DNF security headers (+ `extraHeaders`), gzip
  # and, with `maxUploadSize` (e.g. `"4GB"`), a `request_body` size cap.
  #
  #   proxy.extraConfig = dnfLib.mkCaddySecurityHeaders { maxUploadSize = "4GB"; };
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
