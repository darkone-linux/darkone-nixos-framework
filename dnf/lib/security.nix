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

  # Prédicat d'activation d'une règle ANSSI.
  #
  # Une règle est active ssi :
  #   - le module security est activé ;
  #   - le niveau courant >= sévérité de la règle ;
  #   - la catégorie est compatible (base = universel) ;
  #   - aucun tag de la règle n'est dans `excludes` ;
  #   - il n'existe pas d'exception explicite pour cet identifiant.
  mkIsActive =
    cfg: ruleId: severity: category: tags:
    cfg.enable
    && levelMapping.${severity} <= levelMapping.${cfg.level}
    && (category == "base" || category == cfg.category)
    && lib.all (tag: !(lib.elem tag cfg.excludes)) tags
    && !(lib.hasAttr ruleId cfg.exceptions);
}
