use std::fmt;

#[derive(Debug, Clone)]
pub enum NixValue {
    Str(String),
    Int(i64),
    Float(f64),
    Bool(bool),
}

impl NixValue {
    pub fn string(s: impl Into<String>) -> Self {
        Self::Str(s.into())
    }

    pub fn int(n: i64) -> Self {
        Self::Int(n)
    }

    pub fn float(f: f64) -> Self {
        Self::Float(f)
    }

    pub fn bool(b: bool) -> Self {
        Self::Bool(b)
    }
}

impl fmt::Display for NixValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            // Backslashes must be escaped first to avoid double-escaping the
            // backslash we add for `"`.
            Self::Str(s) => write!(f, "\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"")),
            Self::Int(n) => write!(f, "{n}"),
            Self::Float(n) => write!(f, "{n}"),
            Self::Bool(b) => write!(f, "{b}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    #[test]
    fn string_display() {
        assert_eq!(NixValue::string("hello").to_string(), r#""hello""#);
    }

    #[test]
    fn string_with_quotes_escaped() {
        assert_eq!(
            NixValue::string(r#"say "hi""#).to_string(),
            r#""say \"hi\"""#
        );
    }

    #[test]
    fn bool_display() {
        assert_eq!(NixValue::bool(true).to_string(), "true");
        assert_eq!(NixValue::bool(false).to_string(), "false");
    }

    #[test]
    fn int_display() {
        assert_eq!(NixValue::int(42).to_string(), "42");
    }

    #[test]
    fn float_display() {
        assert_eq!(NixValue::float(PI).to_string(), "3.141592653589793");
    }
}
