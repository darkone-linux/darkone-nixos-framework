# Tests for dnf/lib/security.nix
# Run with: nix-unit --flake .#libTests
{ lib, dnfLib }:
let
  # cfg de base : module activé, niveau minimal, catégorie base, pas d'exclusion ni d'exception
  baseCfg = {
    enable = true;
    level = "minimal";
    category = "base";
    excludes = [ ];
    exceptions = { };
  };
  isActive = dnfLib.mkIsActive;
in
{
  # Module désactivé → jamais actif
  testDisabledModule = {
    expr = isActive (baseCfg // { enable = false; }) "R1" "minimal" "base" [ ];
    expected = false;
  };

  # Niveau suffisant
  testLevelExactMatch = {
    expr = isActive baseCfg "R1" "minimal" "base" [ ];
    expected = true;
  };
  testLevelAbove = {
    expr = isActive (baseCfg // { level = "high"; }) "R1" "intermediary" "base" [ ];
    expected = true;
  };

  # Niveau insuffisant → inactif
  testLevelTooLow = {
    expr = isActive baseCfg "R1" "intermediary" "base" [ ];
    expected = false;
  };

  # Catégorie base = universel
  testCategoryBaseUniversal = {
    expr = isActive (baseCfg // { category = "server"; }) "R1" "minimal" "base" [ ];
    expected = true;
  };

  # Catégorie spécifique : correspondance exacte requise
  testCategoryMatch = {
    expr = isActive (baseCfg // { category = "server"; }) "R1" "minimal" "server" [ ];
    expected = true;
  };
  testCategoryMismatch = {
    expr = isActive (baseCfg // { category = "client"; }) "R1" "minimal" "server" [ ];
    expected = false;
  };

  # Tag dans excludes → inactif
  testExcludedTag = {
    expr = isActive (baseCfg // { excludes = [ "no-auditd" ]; }) "R1" "minimal" "base" [ "no-auditd" ];
    expected = false;
  };

  # Tag non exclu → actif
  testNonExcludedTag = {
    expr = isActive (baseCfg // { excludes = [ "other-tag" ]; }) "R1" "minimal" "base" [ "no-auditd" ];
    expected = true;
  };

  # Exception explicite → inactif
  testException = {
    expr = isActive (baseCfg // { exceptions = { R1 = true; }; }) "R1" "minimal" "base" [ ];
    expected = false;
  };

  # Pas d'exception pour cet id → actif
  testNoExceptionForId = {
    expr = isActive (baseCfg // { exceptions = { R2 = true; }; }) "R1" "minimal" "base" [ ];
    expected = true;
  };

  # levelMapping : ordre correct
  testLevelMappingOrder = {
    expr =
      dnfLib.levelMapping."minimal" < dnfLib.levelMapping."intermediary"
      && dnfLib.levelMapping."intermediary" < dnfLib.levelMapping."reinforced"
      && dnfLib.levelMapping."reinforced" < dnfLib.levelMapping."high";
    expected = true;
  };
}
