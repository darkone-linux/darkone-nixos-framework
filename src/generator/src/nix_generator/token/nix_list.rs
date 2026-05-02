use std::fmt;

use super::nix_value::NixValue;
use super::NixItem;

#[derive(Debug, Default)]
pub struct NixList(Vec<Box<dyn NixItem>>);

impl NixList {
    pub fn new() -> Self {
        Self::default()
    }

    /// Build a list of strings in one shot — covers the vast majority of call sites.
    pub fn from_strings<I, S>(items: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut list = Self::new();
        for s in items {
            list.add_string(s);
        }
        list
    }

    pub fn add(&mut self, item: Box<dyn NixItem>) {
        self.0.push(item);
    }

    pub fn add_string(&mut self, s: impl Into<String>) {
        self.0.push(Box::new(NixValue::string(s)));
    }
}

impl fmt::Display for NixList {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[")?;
        for item in &self.0 {
            write!(f, " {item}")?;
        }
        write!(f, " ]")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_list() {
        assert_eq!(NixList::new().to_string(), "[ ]");
    }

    #[test]
    fn list_with_strings() {
        let mut list = NixList::new();
        list.add_string("alpha");
        list.add_string("beta");
        assert_eq!(list.to_string(), r#"[ "alpha" "beta" ]"#);
    }

    #[test]
    fn from_strings_helper() {
        let list = NixList::from_strings(["a", "b", "c"]);
        assert_eq!(list.to_string(), r#"[ "a" "b" "c" ]"#);
    }
}
