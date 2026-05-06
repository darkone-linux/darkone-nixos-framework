# Tests for dnf/lib/security.nix
# Run with: nix eval --impure --expr 'let lib = (import <nixpkgs> {}).lib; in import ./dnf/tests/unit/lib/security_test.nix { inherit lib; }'

{ lib }:
let
  security = import ../../../lib/security.nix { inherit lib; };

  check = name: cond: if cond then "PASS: ${name}" else throw "FAIL: ${name}";

  # cfg de base : module activé, niveau minimal, catégorie base, pas d'exclusion ni d'exception
  baseCfg = {
    enable = true;
    level = "minimal";
    category = "base";
    excludes = [ ];
    exceptions = { };
  };

  isActive = security.mkIsActive;

in
{
  result =
    # Module désactivé → jamais actif
    check "disabled-module" (!(isActive (baseCfg // { enable = false; }) "R1" "minimal" "base" [ ]))

    # Niveau suffisant
    + " | "
    + check "level-exact-match" (isActive baseCfg "R1" "minimal" "base" [ ])
    + " | "
    + check "level-above" (isActive (baseCfg // { level = "high"; }) "R1" "intermediary" "base" [ ])

    # Niveau insuffisant → inactif
    + " | "
    + check "level-too-low" (!(isActive baseCfg "R1" "intermediary" "base" [ ]))

    # Catégorie base = universel
    + " | "
    + check "category-base-universal" (
      isActive (baseCfg // { category = "server"; }) "R1" "minimal" "base" [ ]
    )

    # Catégorie spécifique : correspondance exacte requise
    + " | "
    + check "category-match" (
      isActive (baseCfg // { category = "server"; }) "R1" "minimal" "server" [ ]
    )
    + " | "
    + check "category-mismatch" (
      !(isActive (baseCfg // { category = "client"; }) "R1" "minimal" "server" [ ])
    )

    # Tag dans excludes → inactif
    + " | "
    + check "excluded-tag" (
      !(isActive (baseCfg // { excludes = [ "no-auditd" ]; }) "R1" "minimal" "base" [ "no-auditd" ])
    )

    # Tag non exclu → actif
    + " | "
    + check "non-excluded-tag" (
      isActive (baseCfg // { excludes = [ "other-tag" ]; }) "R1" "minimal" "base" [ "no-auditd" ]
    )

    # Exception explicite → inactif
    + " | "
    + check "exception" (
      !(isActive (
        baseCfg
        // {
          exceptions = {
            R1 = true;
          };
        }
      ) "R1" "minimal" "base" [ ])
    )

    # Pas d'exception pour cet id → actif
    + " | "
    + check "no-exception-for-id" (
      isActive (
        baseCfg
        // {
          exceptions = {
            R2 = true;
          };
        }
      ) "R1" "minimal" "base" [ ]
    )

    # levelMapping : ordre correct
    + " | "
    + check "levelMapping-order" (
      security.levelMapping."minimal" < security.levelMapping."intermediary"
      && security.levelMapping."intermediary" < security.levelMapping."reinforced"
      && security.levelMapping."reinforced" < security.levelMapping."high"
    );
}
