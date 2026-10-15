# DNF — keyboard of a locale: console keymap (kbd) and XKB layout.
#
# `config/locales.json` lists the locales the installer offers, each with its
# keyboard; `darkone new` reads the same file. Any other canonical locale falls
# back to its country code, which kbd and XKB share for most countries.

{ lib, strings }:
let
  supportedLocales = builtins.fromJSON (builtins.readFile ../config/locales.json);
  byLocale = builtins.listToAttrs (
    map (l: {
      name = l.locale;
      value = l;
    }) supportedLocales
  );
in
{
  inherit supportedLocales;

  # `"en_GB.UTF-8"` -> `{ console = "uk"; xkb = "gb"; xkbVariant = ""; }`.
  keyboardFromLocale =
    locale:
    let
      entry = byLocale.${locale} or null;
      country = strings.extractCountryFromLocale locale;
      code = if country == null then "us" else lib.toLower country;
    in
    if entry == null then
      {
        console = code;
        xkb = code;
        xkbVariant = "";
      }
    else
      {
        inherit (entry) console xkb;
        xkbVariant = entry.xkbVariant or "";
      };
}
