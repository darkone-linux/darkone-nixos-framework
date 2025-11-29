# Strings manipulations

{ lib }:
{
  ucFirst =
    str:
    lib.concatStrings [
      (lib.toUpper (lib.substring 0 1 str))
      (lib.substring 1 (-1) str)
    ];
}
