//! Generic helpers for producing MDX source.

/// Encode `<`, `>`, `&` for safe inclusion in markdown text.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            other => out.push(other),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_html_chars() {
        assert_eq!(escape("a<b & c>d"), "a&lt;b &amp; c&gt;d");
    }
}
