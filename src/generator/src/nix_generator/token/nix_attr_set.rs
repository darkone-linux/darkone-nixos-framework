use std::fmt;

use indexmap::IndexMap;

use super::nix_value::NixValue;
use super::NixItem;

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

    pub fn set_float(&mut self, key: impl Into<String>, value: f64) {
        self.set(key, Box::new(NixValue::float(value)));
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// Keys containing non-alphanumeric/non-underscore chars must be quoted in Nix.
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
