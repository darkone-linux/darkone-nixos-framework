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
# :::tip
# Schema node grammar:
#   { type = "attrs";              # attrs | port | int | string | bool
#     exactKeys = [ ... ];         # (attrs) only these keys are allowed
#     fields = { k = <schema>; };  # (attrs) sub-schema per known key
#     valueType = "port";          # (attrs) type imposed on every value
#     uniqueValues = true; }       # (attrs) values must all be distinct
# Extend by adding a leaf predicate to `leafTypes`; growing a config file means
# enriching its schema, never rewriting the engine or its tests.
# :::

{ lib }:
let
  inherit (builtins)
    isInt
    isString
    isBool
    isAttrs
    ;

  # Leaf value predicates. `port` = internal (non-privileged) service port.
  leafTypes = {
    port = {
      ok = v: isInt v && v >= 1024 && v <= 65535;
      msg = "must be an internal port (int in 1024-65535)";
    };
    int = {
      ok = isInt;
      msg = "must be an int";
    };
    string = {
      ok = isString;
      msg = "must be a string";
    };
    bool = {
      ok = isBool;
      msg = "must be a bool";
    };
  };

  # Human-friendly path label for messages; root has no key yet.
  loc = path: if path == "" then "<root>" else path;
  childPath = path: k: if path == "" then k else "${path}.${k}";

  # Recursive node checker → list of violation strings.
  checkNode =
    path: node: val:
    if node.type == "attrs" then
      checkAttrs path node val
    else
      let
        t = leafTypes.${node.type};
      in
      lib.optional (!(t.ok val)) "${loc path}: ${t.msg}";

  checkAttrs =
    path: node: val:
    if !isAttrs val then
      [ "${loc path}: must be an attrset" ]
    else
      let
        keys = lib.attrNames val;

        # 1. exactKeys: reject any key outside the allowed exhaustive set.
        unknownKeys = lib.optionals (node ? exactKeys) (
          map (
            k: "${loc path}: unknown key \"${k}\" (allowed: ${lib.concatStringsSep ", " node.exactKeys})"
          ) (lib.subtractLists node.exactKeys keys)
        );

        # 2. fields: recurse into each declared sub-key that is present.
        fieldViolations = lib.optionals (node ? fields) (
          lib.concatMap (k: checkNode (childPath path k) node.fields.${k} val.${k}) (
            lib.filter (k: val ? ${k}) (lib.attrNames node.fields)
          )
        );

        # 3. valueType: every leaf value must satisfy the predicate.
        valueTypeViolations = lib.optionals (node ? valueType) (
          lib.concatMap (k: checkNode (childPath path k) { type = node.valueType; } val.${k}) keys
        );

        # 4. uniqueValues: no two entries may share the same value.
        values = lib.attrValues val;
        uniqueViolation = lib.optional (
          (node.uniqueValues or false) && lib.length values != lib.length (lib.unique values)
        ) "${loc path}: values must be unique";
      in
      unknownKeys ++ fieldViolations ++ valueTypeViolations ++ uniqueViolation;
in
{
  checkSchema = schema: value: checkNode "" schema value;
}
