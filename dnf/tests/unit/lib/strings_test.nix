# Tests for dnf/lib/strings.nix
# Run with: nix eval --impure --expr 'let lib = (import <nixpkgs> {}).lib; in import ./dnf/tests/unit/lib/strings_test.nix { inherit lib; }'
# Each test is a boolean - throws if false (fails), returns "PASS" if true

{ lib }:
let
  strings = import ../../../lib/strings.nix { inherit lib; };
  check = name: cond: if cond then "PASS: ${name}" else throw "FAIL: ${name}";
in
{
  result =
    check "ucFirst" (strings.ucFirst "hello" == "Hello")
    + " | "
    + check "ucFirstSingle" (strings.ucFirst "a" == "A")
    + " | "
    + check "ucFirstEmpty" (strings.ucFirst "" == "")
    + " | "
    + check "cleanNewlines" (strings.cleanString "hello\n\n\n\nworld" == "hello\n\nworld")
    + " | "
    + check "cleanClean" (
      strings.cleanString "no consecutive newlines here" == "no consecutive newlines here"
    );
}
