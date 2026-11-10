# DNF unit test suites, auto-discovered: `<dir>/<name>_test.nix` is the suite
# `<dir>_<name>` (`-` → `_`), e.g. `lib/date-time_test.nix` → `lib_date_time`.
# Exposed in flake.nix as .#libTests
# Run with: nix-unit --flake .#libTests
#
# :::note[Suite arguments]
# A suite is a function of what it names among `dnfLib` and `lib`.
# :::
{ lib }:
let
  dnfLib = import ../../lib { inherit lib; };
  args = { inherit dnfLib lib; };
  suffix = "_test.nix";

  entriesOf = type: dir: lib.attrNames (lib.filterAttrs (_: t: t == type) (builtins.readDir dir));

  # nix-unit reads `.` and `-` in an attribute name as a path: `_` only.
  suiteName =
    dir: file: "${dir}_${lib.replaceStrings [ "-" ] [ "_" ] (lib.removeSuffix suffix file)}";

  # Another file name would be silently left out of the run: refused.
  suiteOf =
    dir: file:
    let
      suite = import (./. + "/${dir}/${file}");
    in
    lib.throwIfNot (lib.hasSuffix suffix file)
      "tests/unit/${dir}/${file}: a suite file is named `<name>${suffix}`."
      (
        lib.nameValuePair (suiteName dir file) (
          suite (builtins.intersectAttrs (builtins.functionArgs suite) args)
        )
      );

  suitesOf = dir: map (suiteOf dir) (entriesOf "regular" (./. + "/${dir}"));
in
lib.listToAttrs (lib.concatMap suitesOf (entriesOf "directory" ./.))
