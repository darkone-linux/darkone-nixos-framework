# TODO: Mettre en place la librairie

{ lib }:

with lib;

{
  # Merge profond d'attributs
  mergeDeep =
    lhs: rhs:
    lhs
    // mapAttrs (
      name: value:
      if isAttrs value && lhs ? ${name} && isAttrs lhs.${name} then mergeDeep lhs.${name} value else value
    ) rhs;

  # Filtre les attributs avec une condition
  filterAttrsRecursive =
    pred: set:
    listToAttrs (
      concatMap (
        name:
        let
          value = set.${name};
        in
        optional (pred name value) (
          nameValuePair name (if isAttrs value then filterAttrsRecursive pred value else value)
        )
      ) (attrNames set)
    );
}
