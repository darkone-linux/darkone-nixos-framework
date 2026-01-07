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
}
