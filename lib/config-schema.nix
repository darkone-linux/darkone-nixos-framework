# DNF — config grammar/schema validator (`dnfLib.checkSchema`)
#
# Declarative checker for the `config/*.nix` registries. A *schema* is an
# attrset describing the expected shape; `checkSchema schema value` walks the
# tree and returns a list of human-readable violation strings (empty == valid).
#
# :::note
# Built for nix-unit: assert `checkSchema schema value == [ ]`. The list form
# (not a bool) surfaces *which* constraint failed, prefixed by its path, so a
# failing test points straight at the offending key.
# :::
#
# :::tip Grammar
# Node = attrset with a `type`. Two families: containers and leaves.
#
#   # container
#   { type = "attrs";
#     key = {                         # (opt) constraints on EACH key (a string)
#       oneOf = [ "a" "b" ];          #   allowed key names
#       regex = "[a-zA-Z0-9]+";       #   each key fully matches (builtins.match)
#       fileExists = "modules/service/{{value}}.nix";  # resolved file must exist
#       root = ../../..;              #   Nix path base; {{value}} = the key
#     };
#     fields = { a = <node>; };       # (opt) schema for known keys
#     value = <node>;                 # (opt) schema for every other value
#   }
#
#   # leaves
#   { type = "int"; min = 1024; max = 65535; unique = true; }
#   { type = "string"; regex = "..."; oneOf = [ "x" "y" ]; }
#   { type = "bool"; }
#   { type = "listOfStrings"; unique = true; }
#
# Semantics:
#   - `min`/`max` inclusive; `regex` is a `builtins.match` pattern (fully
#     anchored — no slashes, no ^/$).
#   - `unique` acts at the collection level: on an attrs `value` ⇒ all values
#     distinct; on a `listOfStrings` ⇒ elements distinct.
#   - For a present key, `fields.<key>` wins; otherwise `value` applies.
# :::

{ lib }:
let
  inherit (builtins)
    isInt
    isString
    isBool
    isAttrs
    isList
    match
    replaceStrings
    pathExists
    ;

  # Human-friendly path label for messages; root has no key yet.
  loc = path: if path == "" then "<root>" else path;
  childPath = path: k: if path == "" then k else "${path}.${k}";

  # Resolve a `fileExists` template (`{{value}}` → key) against `key.root`.
  resolveFile = keySpec: key: replaceStrings [ "{{value}}" ] [ key ] keySpec.fileExists;

  # Constraints applied to a single attrs key (a string).
  checkKey =
    path: keySpec: key:
    let
      at = "${loc path}: key \"${key}\"";
    in
    lib.optional (
      keySpec ? oneOf && !(lib.elem key keySpec.oneOf)
    ) "${at} not allowed (oneOf: ${lib.concatStringsSep ", " keySpec.oneOf})"
    ++ lib.optional (
      keySpec ? regex && match keySpec.regex key == null
    ) "${at} does not match regex \"${keySpec.regex}\""
    ++ lib.optional (
      keySpec ? fileExists && !(pathExists (keySpec.root + ("/" + resolveFile keySpec key)))
    ) "${at}: expected file \"${resolveFile keySpec key}\" not found";

  # Recursive node checker → list of violation strings.
  checkNode =
    path: node: val:
    if node.type == "attrs" then
      checkAttrs path node val
    else if node.type == "int" then
      checkInt path node val
    else if node.type == "string" then
      checkString path node val
    else if node.type == "bool" then
      lib.optional (!isBool val) "${loc path}: must be a bool"
    else if node.type == "listOfStrings" then
      checkListOfStrings path node val
    else
      [ "${loc path}: unknown schema type \"${node.type}\"" ];

  checkAttrs =
    path: node: val:
    if !isAttrs val then
      [ "${loc path}: must be an attrset" ]
    else
      let
        keys = lib.attrNames val;
        hasField = k: (node ? fields) && (node.fields ? ${k});

        # Per-key constraints (oneOf / regex / fileExists).
        keyViolations = lib.optionals (node ? key) (lib.concatMap (checkKey path node.key) keys);

        # Known keys → recurse with their declared sub-schema.
        fieldViolations = lib.concatMap (k: checkNode (childPath path k) node.fields.${k} val.${k}) (
          lib.filter (k: val ? ${k}) (lib.attrNames (node.fields or { }))
        );

        # Remaining keys → recurse with the shared `value` schema.
        valueViolations = lib.optionals (node ? value) (
          lib.concatMap (k: checkNode (childPath path k) node.value val.${k}) (
            lib.filter (k: !(hasField k)) keys
          )
        );

        # `value.unique` ⇒ all values across the map must be distinct.
        values = lib.attrValues val;
        uniqueViolation = lib.optional (
          (node ? value)
          && (node.value.unique or false)
          && lib.length values != lib.length (lib.unique values)
        ) "${loc path}: values must be unique";
      in
      keyViolations ++ fieldViolations ++ valueViolations ++ uniqueViolation;

  checkInt =
    path: node: val:
    if !isInt val then
      [ "${loc path}: must be an int" ]
    else
      lib.optional (node ? min && val < node.min) "${loc path}: must be >= ${toString node.min}"
      ++ lib.optional (node ? max && val > node.max) "${loc path}: must be <= ${toString node.max}";

  checkString =
    path: node: val:
    if !isString val then
      [ "${loc path}: must be a string" ]
    else
      lib.optional (
        node ? regex && match node.regex val == null
      ) "${loc path}: must match regex \"${node.regex}\""
      ++ lib.optional (
        node ? oneOf && !(lib.elem val node.oneOf)
      ) "${loc path}: must be one of ${lib.concatStringsSep ", " node.oneOf}";

  checkListOfStrings =
    path: node: val:
    if !(isList val && lib.all isString val) then
      [ "${loc path}: must be a list of strings" ]
    else
      lib.optional (
        (node.unique or false) && lib.length val != lib.length (lib.unique val)
      ) "${loc path}: list elements must be unique";
in
{
  checkSchema = schema: value: checkNode "" schema value;
}
