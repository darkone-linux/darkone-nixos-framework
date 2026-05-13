# Helpers for the security modules (ANSSI rules).

{ lib }:
let
  levelMapping = {
    "minimal" = 0;
    "intermediary" = 1;
    "reinforced" = 2;
    "high" = 3;
  };
in
{
  inherit levelMapping;

  # Activation predicate for an ANSSI rule.
  #
  # A rule is active iff:
  #   - the security module is enabled;
  #   - current level >= rule severity;
  #   - the category is compatible (base = universal);
  #   - none of the rule tags is in `excludes`;
  #   - no explicit exception exists for this identifier.
  mkIsActive =
    cfg: ruleId: severity: category: tags:
    cfg.enable
    && levelMapping.${severity} <= levelMapping.${cfg.level}
    && (category == "base" || category == cfg.category)
    && lib.all (tag: !(lib.elem tag cfg.excludes)) tags
    && !(lib.hasAttr ruleId cfg.exceptions);
}
