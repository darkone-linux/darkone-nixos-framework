# Tests for dnf/lib/i18n.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }: {

  # French keeps the layout and variant it always had.
  testKeyboardFrance = {
    expr = dnfLib.keyboardFromLocale "fr_FR.UTF-8";
    expected = {
      console = "fr";
      xkb = "fr";
      xkbVariant = "oss";
    };
  };

  # kbd and XKB disagree on the name: `uk` on the console, `gb` in XKB.
  testKeyboardUnitedKingdom = {
    expr = dnfLib.keyboardFromLocale "en_GB.UTF-8";
    expected = {
      console = "uk";
      xkb = "gb";
      xkbVariant = "";
    };
  };
  testKeyboardSwissFrench = {
    expr = dnfLib.keyboardFromLocale "fr_CH.UTF-8";
    expected = {
      console = "fr_CH";
      xkb = "ch";
      xkbVariant = "fr";
    };
  };

  # Outside the table: the country code, as before the table existed.
  testKeyboardFallbackCountry = {
    expr = dnfLib.keyboardFromLocale "ru_RU.UTF-8";
    expected = {
      console = "ru";
      xkb = "ru";
      xkbVariant = "";
    };
  };
  testKeyboardFallbackNotCanonical = {
    expr = (dnfLib.keyboardFromLocale "C.UTF-8").console;
    expected = "us";
  };

  # Every entry the installer offers is complete and canonical.
  testSupportedLocalesWellFormed = {
    expr = builtins.all (
      l:
      builtins.match "[a-z]{2}_[A-Z]{2}\\.UTF-8" l.locale != null
      && l.label != ""
      && l.console != ""
      && l.xkb != ""
    ) dnfLib.supportedLocales;
    expected = true;
  };
}
