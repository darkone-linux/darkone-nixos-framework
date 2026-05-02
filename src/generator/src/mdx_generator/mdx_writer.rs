//! Generic helpers for producing MDX source.
//!
//! Kept tiny on purpose — anything specific to a particular doc page lives
//! next to that page's generator.

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

/// Build a Starlight-style YAML frontmatter block.
pub fn frontmatter(lines: &[(&str, &str)]) -> String {
    let mut out = String::from("---\n");
    for (k, v) in lines {
        out.push_str(k);
        out.push_str(": ");
        out.push_str(v);
        out.push('\n');
    }
    out.push_str("---\n");
    out
}

/// Wrap a Nix snippet in a fenced ` ```nix … ``` ` block.
pub fn nix_code_block(body: &str) -> String {
    format!("```nix\n{body}```\n")
}
