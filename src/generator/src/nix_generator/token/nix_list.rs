use std::fmt;

use super::NixItem;

#[derive(Debug, Default)]
pub struct NixList(Vec<Box<dyn NixItem>>);

impl NixList {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&mut self, item: Box<dyn NixItem>) {
        self.0.push(item);
    }

    pub fn add_string(&mut self, s: impl Into<String>) {
        use super::nix_value::NixValue;
        self.0.push(Box::new(NixValue::string(s)));
    }

    pub fn add_int(&mut self, n: i64) {
        use super::nix_value::NixValue;
        self.0.push(Box::new(NixValue::int(n)));
    }

    pub fn populate(&mut self, items: Vec<Box<dyn NixItem>>) {
        self.0.extend(items);
    }

    pub fn populate_strings(&mut self, strings: Vec<impl Into<String>>) {
        for s in strings {
            self.add_string(s);
        }
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn len(&self) -> usize {
        self.0.len()
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
    fn list_with_ints() {
        let mut list = NixList::new();
        list.add_int(1);
        list.add_int(2);
        assert_eq!(list.to_string(), "[ 1 2 ]");
    }

    #[test]
    fn populate_strings() {
        let mut list = NixList::new();
        list.populate_strings(vec!["a", "b", "c"]);
        assert_eq!(list.to_string(), r#"[ "a" "b" "c" ]"#);
    }
}
