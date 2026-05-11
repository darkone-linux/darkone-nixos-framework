# Tests for dnf/lib/strings.nix
# Run with: nix-unit --flake .#libTests
{ lib, dnfLib }:
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
}
