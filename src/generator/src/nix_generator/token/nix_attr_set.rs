use std::fmt;

use indexmap::IndexMap;

use super::nix_value::NixValue;
use super::NixItem;

/// Ordered Nix attribute set: insertion order is preserved in the output, which
/// matters because we want generated files to diff stably.
#[derive(Debug, Default)]
pub struct NixAttrSet(IndexMap<String, Box<dyn NixItem>>);

impl NixAttrSet {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&mut self, key: impl Into<String>, value: Box<dyn NixItem>) {
        self.0.insert(key.into(), value);
    }

    pub fn set_string(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.set(key, Box::new(NixValue::string(value)));
    }

    pub fn set_int(&mut self, key: impl Into<String>, value: i64) {
        self.set(key, Box::new(NixValue::int(value)));
    }

    pub fn set_bool(&mut self, key: impl Into<String>, value: bool) {
        self.set(key, Box::new(NixValue::bool(value)));
    }

    /// Keys with non-identifier characters (e.g. an IP address used as a key)
    /// must be quoted in the Nix source.
    fn needs_quoting(key: &str) -> bool {
        !key.chars()
            .all(|c| c.is_alphanumeric() || c == '_' || c == '-')
    }
}

impl fmt::Display for NixAttrSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{{")?;
        for (key, value) in &self.0 {
            if Self::needs_quoting(key) {
                write!(f, " \"{key}\" = {value};")?;
            } else {
                write!(f, " {key} = {value};")?;
            }
        }
        write!(f, " }}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_attr_set() {
        assert_eq!(NixAttrSet::new().to_string(), "{ }");
    }

    #[test]
    fn simple_key() {
        let mut s = NixAttrSet::new();
        s.set_string("name", "alice");
        assert_eq!(s.to_string(), r#"{ name = "alice"; }"#);
    }

    #[test]
    fn complex_key_with_dots() {
        let mut s = NixAttrSet::new();
        s.set_string("10.0.0.1", "gateway");
        assert_eq!(s.to_string(), r#"{ "10.0.0.1" = "gateway"; }"#);
    }

    #[test]
    fn bool_value() {
        let mut s = NixAttrSet::new();
        s.set_bool("enable", true);
        assert_eq!(s.to_string(), "{ enable = true; }");
    }

    #[test]
    fn int_value() {
        let mut s = NixAttrSet::new();
        s.set_int("uid", 1000);
        assert_eq!(s.to_string(), "{ uid = 1000; }");
    }

    #[test]
    fn nested_attr_set() {
        let mut inner = NixAttrSet::new();
        inner.set_bool("enable", true);
        let mut outer = NixAttrSet::new();
        outer.set("service", Box::new(inner));
        assert_eq!(outer.to_string(), "{ service = { enable = true; }; }");
    }

    #[test]
    fn insertion_order_preserved() {
        let mut s = NixAttrSet::new();
        s.set_string("z", "last");
        s.set_string("a", "first");
        let out = s.to_string();
        assert!(out.find("z =").unwrap() < out.find("a =").unwrap());
    }
}
