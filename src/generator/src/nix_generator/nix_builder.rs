use serde_yaml::Value;

use super::token::{NixAttrSet, NixItem, NixList, NixValue};

/// Recursively convert a serde_yaml Value into a boxed NixItem.
pub fn array_to_nix(value: &Value) -> Box<dyn NixItem> {
    match value {
        Value::Mapping(map) => {
            let mut attr_set = NixAttrSet::new();
            for (k, v) in map {
                let key = match k {
                    Value::String(s) => s.clone(),
                    other => format!("{other:?}"),
                };
                attr_set.set(key, array_to_nix(v));
            }
            Box::new(attr_set)
        }
        Value::Sequence(seq) => {
            let mut list = NixList::new();
            for item in seq {
                list.add(array_to_nix(item));
            }
            Box::new(list)
        }
        Value::String(s) => Box::new(NixValue::string(s)),
        Value::Bool(b) => Box::new(NixValue::bool(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Box::new(NixValue::int(i))
            } else if let Some(f) = n.as_f64() {
                Box::new(NixValue::float(f))
            } else {
                Box::new(NixValue::string(n.to_string()))
            }
        }
        Value::Null => Box::new(NixAttrSet::new()),
        Value::Tagged(tagged) => array_to_nix(&tagged.value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_yaml::from_str;

    fn nix(yaml: &str) -> String {
        array_to_nix(&from_str(yaml).unwrap()).to_string()
    }

    #[test]
    fn string_scalar() {
        assert_eq!(nix("hello"), r#""hello""#);
    }

    #[test]
    fn bool_true() {
        assert_eq!(nix("true"), "true");
    }

    #[test]
    fn int_scalar() {
        assert_eq!(nix("42"), "42");
    }

    #[test]
    fn sequence_becomes_list() {
        assert_eq!(nix("- a\n- b"), r#"[ "a" "b" ]"#);
    }

    #[test]
    fn mapping_becomes_attr_set() {
        assert_eq!(nix("key: val"), r#"{ key = "val"; }"#);
    }

    #[test]
    fn null_becomes_empty_attr_set() {
        assert_eq!(nix("~"), "{ }");
    }

    #[test]
    fn nested_mapping() {
        let yaml = "outer:\n  inner: 1";
        assert_eq!(nix(yaml), "{ outer = { inner = 1; }; }");
    }

    #[test]
    fn mixed_types_in_mapping() {
        let yaml = "name: foo\nenabled: true\ncount: 3";
        let out = nix(yaml);
        assert!(out.contains(r#"name = "foo""#));
        assert!(out.contains("enabled = true"));
        assert!(out.contains("count = 3"));
    }
}
