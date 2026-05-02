//! Tiny helpers for navigating `serde_yaml::Value` trees.
//!
//! The PHP generator was permissive about missing/empty keys — these helpers
//! preserve that flavour so loaders don't drown in `.and_then(|v| v.as_…)?`
//! ladders.

use std::collections::HashMap;

use serde_yaml::Value;

/// Read `value[key]` as a string, returning `None` for missing or non-string entries.
pub fn as_str_opt<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// Read `value[key]` as a sequence of strings; absent / non-sequence yields `[]`.
pub fn as_string_vec(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(Value::as_sequence)
        .map(|seq| {
            seq.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// Convert a YAML mapping to `HashMap<String, Value>`, dropping non-string keys.
pub fn to_string_map(value: Value) -> HashMap<String, Value> {
    match value {
        Value::Mapping(m) => m
            .into_iter()
            .filter_map(|(k, v)| Some((k.as_str()?.to_string(), v)))
            .collect(),
        _ => HashMap::new(),
    }
}

/// Recursively merge two YAML values; `overlay` keys win over `base`.
pub fn deep_merge(base: Value, overlay: Value) -> Value {
    match (base, overlay) {
        (Value::Mapping(mut b), Value::Mapping(o)) => {
            for (k, v) in o {
                let merged = match b.remove(&k) {
                    Some(bv) => deep_merge(bv, v),
                    None => v,
                };
                b.insert(k, merged);
            }
            Value::Mapping(b)
        }
        (_, o) => o,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn yaml(src: &str) -> Value {
        serde_yaml::from_str(src).unwrap()
    }

    #[test]
    fn as_string_vec_present() {
        let v = yaml("groups:\n  - a\n  - b\n");
        assert_eq!(as_string_vec(&v, "groups"), vec!["a", "b"]);
    }

    #[test]
    fn as_string_vec_missing() {
        let v = yaml("other: 1");
        assert!(as_string_vec(&v, "groups").is_empty());
    }

    #[test]
    fn as_str_opt_string() {
        let v = yaml("name: alice");
        assert_eq!(as_str_opt(&v, "name"), Some("alice"));
        assert_eq!(as_str_opt(&v, "missing"), None);
    }

    #[test]
    fn deep_merge_overlay_wins() {
        let base = yaml("a: 1\nb:\n  x: old\n  y: kept\n");
        let overlay = yaml("b:\n  x: new\nc: 3\n");
        let merged = deep_merge(base, overlay);
        let m = merged.as_mapping().unwrap();
        let b = m.get(Value::from("b")).unwrap().as_mapping().unwrap();
        assert_eq!(b.get(Value::from("x")).unwrap().as_str(), Some("new"));
        assert_eq!(b.get(Value::from("y")).unwrap().as_str(), Some("kept"));
        assert_eq!(m.get(Value::from("c")).unwrap().as_i64(), Some(3));
    }
}
