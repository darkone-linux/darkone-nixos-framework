# Tests for dnf/lib/security.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let

  # Module enabled, minimal level, base category, no exclusion or exception.
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

  # Disabled module → never active
  testDisabledModule = {
    expr = isActive (baseCfg // { enable = false; }) "R1" "minimal" "base" [ ];
    expected = false;
  };

  # Level reached
  testLevelExactMatch = {
    expr = isActive baseCfg "R1" "minimal" "base" [ ];
    expected = true;
  };
  testLevelAbove = {
    expr = isActive (baseCfg // { level = "high"; }) "R1" "intermediary" "base" [ ];
    expected = true;
  };

  # Level too low → inactive
  testLevelTooLow = {
    expr = isActive baseCfg "R1" "intermediary" "base" [ ];
    expected = false;
  };

  # Base category = universal
  testCategoryBaseUniversal = {
    expr = isActive (baseCfg // { category = "server"; }) "R1" "minimal" "base" [ ];
    expected = true;
  };

  # Specific category: exact match required
  testCategoryMatch = {
    expr = isActive (baseCfg // { category = "server"; }) "R1" "minimal" "server" [ ];
    expected = true;
  };
  testCategoryMismatch = {
    expr = isActive (baseCfg // { category = "client"; }) "R1" "minimal" "server" [ ];
    expected = false;
  };

  # Excluded tag → inactive
  testExcludedTag = {
    expr = isActive (baseCfg // { excludes = [ "no-auditd" ]; }) "R1" "minimal" "base" [ "no-auditd" ];
    expected = false;
  };

  # Tag not excluded → active
  testNonExcludedTag = {
    expr = isActive (baseCfg // { excludes = [ "other-tag" ]; }) "R1" "minimal" "base" [ "no-auditd" ];
    expected = true;
  };

  # Explicit exception → inactive
  testException = {
    expr = isActive (
      baseCfg
      // {
        exceptions = {
          R1 = true;
        };
      }
    ) "R1" "minimal" "base" [ ];
    expected = false;
  };

  # Exception for another rule → active
  testNoExceptionForId = {
    expr = isActive (
      baseCfg
      // {
        exceptions = {
          R2 = true;
        };
      }
    ) "R1" "minimal" "base" [ ];
    expected = true;
  };

  # levelMapping: levels in increasing order
  testLevelMappingOrder = {
    expr =
      dnfLib.levelMapping."minimal" < dnfLib.levelMapping."intermediary"
      && dnfLib.levelMapping."intermediary" < dnfLib.levelMapping."reinforced"
      && dnfLib.levelMapping."reinforced" < dnfLib.levelMapping."high";
    expected = true;
  };

  # mkHardenedServiceConfig: baseline R52/R55/R63 keys present
  testHardenedBaseline = {
    expr =
      let
        c = dnfLib.mkHardenedServiceConfig { };
      in
      c.ProtectSystem == "strict" && c.RuntimeDirectoryMode == "0750" && c.PrivateTmp == true;
    expected = true;
  };

  # W^X enabled by default (no JIT runtime)
  testHardenedMemoryDenyDefault = {
    expr = (dnfLib.mkHardenedServiceConfig { }).MemoryDenyWriteExecute or false;
    expected = true;
  };

  # needs-jit drops MemoryDenyWriteExecute (key absent)
  testHardenedNeedsJit = {
    expr = (dnfLib.mkHardenedServiceConfig { needsJit = true; }) ? MemoryDenyWriteExecute;
    expected = false;
  };
}
