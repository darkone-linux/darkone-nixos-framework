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

    pub fn force_string(self) -> Self {
        match self {
            Self::Str(_) => self,
            Self::Int(n) => Self::Str(n.to_string()),
            Self::Float(f) => Self::Str(f.to_string()),
            Self::Bool(b) => Self::Str(b.to_string()),
        }
    }

    pub fn force_int(self) -> Self {
        match self {
            Self::Int(_) => self,
            Self::Str(s) => Self::Int(s.parse().unwrap_or(0)),
            Self::Float(f) => Self::Int(f as i64),
            Self::Bool(b) => Self::Int(if b { 1 } else { 0 }),
        }
    }

    pub fn force_bool(self) -> Self {
        match self {
            Self::Bool(_) => self,
            Self::Str(s) => Self::Bool(!s.is_empty() && s != "false" && s != "0"),
            Self::Int(n) => Self::Bool(n != 0),
            Self::Float(f) => Self::Bool(f != 0.0),
        }
    }
}

impl fmt::Display for NixValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
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
    fn bool_true() {
        assert_eq!(NixValue::bool(true).to_string(), "true");
    }

    #[test]
    fn bool_false() {
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

    #[test]
    fn force_string_from_int() {
        assert_eq!(NixValue::int(7).force_string().to_string(), r#""7""#);
    }

    #[test]
    fn force_int_from_str() {
        assert_eq!(NixValue::string("42").force_int().to_string(), "42");
    }

    #[test]
    fn force_bool_from_int() {
        assert_eq!(NixValue::int(1).force_bool().to_string(), "true");
        assert_eq!(NixValue::int(0).force_bool().to_string(), "false");
    }
}
