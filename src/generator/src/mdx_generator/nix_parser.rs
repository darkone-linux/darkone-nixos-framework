//! Generic helpers for extracting documentation from Nix module sources.
//!
//! Built on top of `rnix` to traverse the AST instead of pattern-matching
//! source lines. Other generators can reuse these primitives to scan modules.

use std::path::{Path, PathBuf};

use rnix::ast::{self, Attr, Expr, HasEntry};
use rnix::{NodeOrToken, SyntaxKind};
use rowan::ast::AstNode as _;

/// One declared option within a module.
#[derive(Debug, Clone)]
pub struct NixOption {
    /// Dotted name relative to the enclosing options block
    /// (e.g. `service`, `service.persist.dirs`, `domain`).
    pub name: String,
    /// 1 = top-level option, 2 = inside a submodule, 3 = nested submodule…
    pub level: usize,
    /// Simplified type label (`bool`, `str`, `submodule`, `attrs`, `lines`, …).
    pub type_label: String,
    /// Source text of `default = …` if present.
    pub default: Option<String>,
    /// Source text of `example = …` if present.
    pub example: Option<String>,
    /// Plain (unquoted) description.
    pub description: Option<String>,
}

/// First top-of-file `# …` comment block, with leading `#` and shared spaces removed.
pub fn extract_first_comment(source: &str) -> Option<String> {
    let parsed = rnix::Root::parse(source);
    let root = parsed.syntax();
    let mut buf = Vec::<String>::new();
    for elem in root.children_with_tokens() {
        match elem {
            NodeOrToken::Token(tok) => match tok.kind() {
                SyntaxKind::TOKEN_COMMENT => {
                    let line = strip_comment_marker(tok.text());
                    buf.push(line);
                }
                SyntaxKind::TOKEN_WHITESPACE => {
                    if buf.is_empty() {
                        continue;
                    }
                    // Stop at the first blank line that follows the comment block.
                    if tok.text().matches('\n').count() >= 2 {
                        break;
                    }
                }
                _ => break,
            },
            NodeOrToken::Node(_) => break,
        }
    }
    if buf.is_empty() {
        return None;
    }
    Some(buf.join("\n"))
}

fn strip_comment_marker(raw: &str) -> String {
    // rnix sees a comment as a single token that includes leading `#`
    // (and possibly multiple lines for `# …` style).
    let mut out = String::new();
    for (i, line) in raw.lines().enumerate() {
        let cleaned = line.trim_start().trim_start_matches('#');
        let cleaned = cleaned.strip_prefix(' ').unwrap_or(cleaned);
        if i > 0 {
            out.push('\n');
        }
        out.push_str(cleaned);
    }
    out
}

/// "dnf/modules/standard/service/foo.nix" with prefix "darkone." → "darkone.service.foo".
pub fn extract_module_path(file: &Path, base: &Path, prefix: &str) -> String {
    let rel = file.strip_prefix(base).unwrap_or(file);
    let without_ext = rel.with_extension("");
    let parts: Vec<&str> = without_ext
        .components()
        .filter_map(|c| c.as_os_str().to_str())
        .collect();
    if parts.is_empty() {
        return prefix.trim_end_matches('.').to_string();
    }
    format!("{prefix}{}", parts.join("."))
}

/// Recursively list `*.nix` files (excluding `default.nix`), sorted.
pub fn extract_nix_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    walk(dir, &mut out);
    out.sort();
    out
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("nix")
            && path.file_name().and_then(|n| n.to_str()) != Some("default.nix")
        {
            out.push(path);
        }
    }
}

/// Parse a module source and return the flat, ordered list of declared options.
/// Submodule contents appear right after their parent with `level + 1`.
pub fn parse_module_options(source: &str) -> Vec<NixOption> {
    let parsed = rnix::Root::parse(source);
    let Some(expr) = parsed.tree().expr() else {
        return vec![];
    };
    let Some(options_attrset) = find_options_attrset(&expr) else {
        return vec![];
    };

    // The first non-trivial binding's attrpath determines the module prefix
    // we strip from all sibling bindings (e.g. `darkone.host.gateway`).
    let bindings: Vec<ast::AttrpathValue> = options_attrset.attrpath_values().collect();
    let prefix = common_module_prefix(&bindings);

    let mut out = vec![];
    for binding in &bindings {
        let attrpath = binding.attrpath();
        let value = binding.value();
        let (Some(attrpath), Some(value)) = (attrpath, value) else {
            continue;
        };
        let dotted = attrpath_to_dotted(&attrpath);
        let name = strip_prefix(&dotted, &prefix);
        if name.is_empty() {
            continue;
        }
        collect_option(&mut out, &name, 1, &value);
    }
    out
}

/// Walks the file's top expression to locate the attrset that holds `options = { … }`.
fn find_options_attrset(expr: &Expr) -> Option<ast::AttrSet> {
    let body = innermost_body(expr.clone());
    let attrset = match body {
        Expr::AttrSet(set) => set,
        _ => return None,
    };
    for av in attrset.attrpath_values() {
        let dotted = av.attrpath().map(|p| attrpath_to_dotted(&p)).unwrap_or_default();
        if dotted == "options" {
            if let Some(Expr::AttrSet(inner)) = av.value() {
                return Some(inner);
            }
        }
    }
    None
}

/// Strips the wrapping function/let/with/assert around the module's returned attrset.
fn innermost_body(mut expr: Expr) -> Expr {
    loop {
        match expr {
            Expr::Lambda(l) => match l.body() {
                Some(b) => expr = b,
                None => return Expr::Lambda(l),
            },
            Expr::LetIn(l) => match l.body() {
                Some(b) => expr = b,
                None => return Expr::LetIn(l),
            },
            Expr::With(w) => match w.body() {
                Some(b) => expr = b,
                None => return Expr::With(w),
            },
            Expr::Assert(a) => match a.body() {
                Some(b) => expr = b,
                None => return Expr::Assert(a),
            },
            Expr::Paren(p) => match p.expr() {
                Some(b) => expr = b,
                None => return Expr::Paren(p),
            },
            other => return other,
        }
    }
}

fn common_module_prefix(bindings: &[ast::AttrpathValue]) -> String {
    // For darkone modules the prefix is everything but the last attr of the
    // first binding (e.g. `darkone.host.gateway` from `darkone.host.gateway.enable`).
    for av in bindings {
        let Some(path) = av.attrpath() else { continue };
        let attrs: Vec<String> = path.attrs().map(|a| attr_to_string(&a)).collect();
        if attrs.len() < 2 {
            return String::new();
        }
        return attrs[..attrs.len() - 1].join(".");
    }
    String::new()
}

fn strip_prefix(dotted: &str, prefix: &str) -> String {
    if prefix.is_empty() {
        return dotted.to_string();
    }
    if let Some(rest) = dotted.strip_prefix(prefix) {
        return rest.trim_start_matches('.').to_string();
    }
    dotted.to_string()
}

fn collect_option(out: &mut Vec<NixOption>, name: &str, level: usize, value: &Expr) {
    let Some(call) = option_call(value) else {
        return;
    };
    match call {
        OptionCall::Enable { description } => {
            out.push(NixOption {
                name: name.to_string(),
                level,
                type_label: "bool".into(),
                default: Some("false".into()),
                example: None,
                description: Some(description),
            });
        }
        OptionCall::MkOption { fields } => {
            let raw_type = fields.option_type.clone();
            let type_label = simplify_type(raw_type.as_deref());
            let mut option = NixOption {
                name: name.to_string(),
                level,
                type_label: type_label.clone(),
                default: fields.default.clone(),
                example: fields.example.clone(),
                description: fields.description.clone(),
            };

            // Defaults forced by simplified types (mirrors PHP's MdxParser logic).
            match type_label.as_str() {
                "submodule" | "attrs" => {
                    option.default = Some("{ }".into());
                    option.example = None;
                }
                "lines" => {
                    option.default = Some("\"\"".into());
                    option.example = None;
                }
                t if t.starts_with("listOf") => {
                    option.default = Some("[ ]".into());
                    option.example = None;
                }
                _ => {}
            }
            out.push(option);

            if let Some(ty) = &fields.type_expr {
                if let Some(submodule_options) = find_submodule_options(ty) {
                    let inner_bindings: Vec<ast::AttrpathValue> =
                        submodule_options.attrpath_values().collect();
                    for inner in &inner_bindings {
                        let (Some(p), Some(v)) = (inner.attrpath(), inner.value()) else {
                            continue;
                        };
                        let inner_name = attrpath_to_dotted(&p);
                        if inner_name.is_empty() {
                            continue;
                        }
                        collect_option(out, &inner_name, level + 1, &v);
                    }
                }
            }
        }
    }
}

#[derive(Default, Clone)]
struct MkOptionFields {
    option_type: Option<String>,
    type_expr: Option<Expr>,
    default: Option<String>,
    example: Option<String>,
    description: Option<String>,
}

enum OptionCall {
    Enable { description: String },
    MkOption { fields: MkOptionFields },
}

fn option_call(expr: &Expr) -> Option<OptionCall> {
    let apply = match expr {
        Expr::Apply(a) => a.clone(),
        Expr::Paren(p) => return p.expr().and_then(|e| option_call(&e)),
        _ => return None,
    };
    let lambda = apply.lambda()?;
    let argument = apply.argument()?;
    let fname = trailing_ident_name(&lambda)?;
    match fname.as_str() {
        "mkEnableOption" => {
            let description = expr_string_value(&argument).unwrap_or_default();
            Some(OptionCall::Enable { description })
        }
        "mkOption" => {
            let attrs = unwrap_attrset(&argument)?;
            let mut fields = MkOptionFields::default();
            for av in attrs.attrpath_values() {
                let (Some(p), Some(v)) = (av.attrpath(), av.value()) else {
                    continue;
                };
                let key = attrpath_to_dotted(&p);
                match key.as_str() {
                    "type" => {
                        fields.option_type = Some(simplify_types_prefix(&node_text(&v)));
                        fields.type_expr = Some(v);
                    }
                    "default" => fields.default = Some(node_text(&v)),
                    "example" => fields.example = Some(node_text(&v)),
                    "description" => {
                        fields.description = Some(expr_string_value(&v).unwrap_or_else(|| node_text(&v)));
                    }
                    _ => {}
                }
            }
            Some(OptionCall::MkOption { fields })
        }
        _ => None,
    }
}

/// Resolves `mkOption` / `lib.mkOption` / `pkgs.lib.mkOption` to "mkOption".
fn trailing_ident_name(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Ident(i) => Some(i.ident_token()?.text().to_string()),
        Expr::Select(sel) => {
            let path = sel.attrpath()?;
            let attrs: Vec<String> = path.attrs().map(|a| attr_to_string(&a)).collect();
            attrs.last().cloned()
        }
        Expr::Paren(p) => trailing_ident_name(&p.expr()?),
        _ => None,
    }
}

fn unwrap_attrset(expr: &Expr) -> Option<ast::AttrSet> {
    match expr {
        Expr::AttrSet(s) => Some(s.clone()),
        Expr::Paren(p) => unwrap_attrset(&p.expr()?),
        _ => None,
    }
}

/// Source text for any expression (preserves formatting).
fn node_text(expr: &Expr) -> String {
    expr.syntax().text().to_string()
}

/// Strip surrounding quotes for plain string literals; otherwise return raw text.
fn expr_string_value(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Str(s) => {
            // Concatenate literal parts; interpolation pieces are kept as raw text.
            let mut out = String::new();
            for part in s.normalized_parts() {
                match part {
                    ast::InterpolPart::Literal(lit) => out.push_str(&lit),
                    ast::InterpolPart::Interpolation(interp) => {
                        out.push_str("${");
                        if let Some(inner) = interp.expr() {
                            out.push_str(&node_text(&inner));
                        }
                        out.push('}');
                    }
                }
            }
            Some(out)
        }
        Expr::Paren(p) => p.expr().and_then(|e| expr_string_value(&e)),
        _ => None,
    }
}

fn attrpath_to_dotted(path: &ast::Attrpath) -> String {
    path.attrs()
        .map(|a| attr_to_string(&a))
        .collect::<Vec<_>>()
        .join(".")
}

fn attr_to_string(attr: &Attr) -> String {
    match attr {
        Attr::Ident(i) => i.ident_token().map(|t| t.text().to_string()).unwrap_or_default(),
        Attr::Str(s) => expr_string_value(&Expr::Str(s.clone())).unwrap_or_default(),
        Attr::Dynamic(d) => d.syntax().text().to_string(),
    }
}

/// Strip `lib.types.` / `types.` prefixes from a type source-text expression.
fn simplify_types_prefix(raw: &str) -> String {
    // Same intent as PHP's `preg_replace('/(lib\.)?types\./', '', …)`.
    let mut s = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        if c == 'l' && starts_with_at(&chars, "ib.types.") {
            for _ in 0..9 {
                chars.next();
            }
            continue;
        }
        if c == 't' && starts_with_at(&chars, "ypes.") {
            for _ in 0..5 {
                chars.next();
            }
            continue;
        }
        s.push(c);
    }
    // Collapse whitespace runs (for cleaner labels like `listOf str`).
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn starts_with_at(chars: &std::iter::Peekable<std::str::Chars>, needle: &str) -> bool {
    let cloned: String = chars.clone().take(needle.len()).collect();
    cloned == needle
}

/// Reduces an arbitrary type expression to one of the well-known short labels.
fn simplify_type(raw: Option<&str>) -> String {
    let raw = match raw {
        Some(r) if !r.trim().is_empty() => r.trim().to_string(),
        _ => return String::new(),
    };
    if raw.starts_with("submodule") {
        "submodule".into()
    } else if raw.starts_with("attrs") {
        "attrs".into()
    } else if raw.starts_with("lines") {
        "lines".into()
    } else if raw.starts_with("listOf") {
        // Keep "listOf X" so the bullet shows the inner element type.
        let mut parts = raw.split_whitespace();
        let head = parts.next().unwrap_or("listOf");
        let tail: Vec<&str> = parts.collect();
        if tail.is_empty() {
            head.into()
        } else {
            format!("{head} {}", tail.join(" "))
        }
    } else {
        raw
    }
}

/// Locate the `options = { … }` attrset inside a `submodule (…)` type expression.
fn find_submodule_options(type_expr: &Expr) -> Option<ast::AttrSet> {
    // Common shapes:
    //   types.submodule { options = { … }; }
    //   types.submodule (_: { options = { … }; })
    //   types.attrsOf (types.submodule (…))
    let mut current = type_expr.clone();
    loop {
        match current {
            Expr::Apply(apply) => {
                let lambda = apply.lambda();
                let fname = lambda.as_ref().and_then(trailing_ident_name);
                let arg = apply.argument()?;
                match fname.as_deref() {
                    Some("submodule") => {
                        return options_in_submodule_arg(&arg);
                    }
                    Some("attrsOf") | Some("nullOr") | Some("listOf") => {
                        current = arg;
                    }
                    _ => return None,
                }
            }
            Expr::Paren(p) => match p.expr() {
                Some(inner) => current = inner,
                None => return None,
            },
            _ => return None,
        }
    }
}

fn options_in_submodule_arg(arg: &Expr) -> Option<ast::AttrSet> {
    match arg {
        Expr::AttrSet(set) => find_options_inside(set),
        Expr::Paren(p) => p.expr().and_then(|e| options_in_submodule_arg(&e)),
        Expr::Lambda(l) => {
            let body = l.body()?;
            options_in_submodule_arg(&body)
        }
        _ => None,
    }
}

fn find_options_inside(set: &ast::AttrSet) -> Option<ast::AttrSet> {
    for av in set.attrpath_values() {
        let path = av.attrpath()?;
        let attrs: Vec<String> = path.attrs().map(|a| attr_to_string(&a)).collect();
        if attrs.first().map(|s| s.as_str()) == Some("options") {
            if let Some(Expr::AttrSet(inner)) = av.value() {
                return Some(inner);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_comment_block() {
        let src = "# A nice module.\n#\n# :::note\n# Stuff\n# :::\n\n{ ... }: {}\n";
        let c = extract_first_comment(src).unwrap();
        assert!(c.starts_with("A nice module."));
        assert!(c.contains(":::note"));
    }

    #[test]
    fn no_comment() {
        let src = "{ ... }: {}";
        assert!(extract_first_comment(src).is_none());
    }

    #[test]
    fn module_path_dnf_layout() {
        let base = Path::new("/repo/dnf/modules/standard");
        let file = Path::new("/repo/dnf/modules/standard/service/adguardhome.nix");
        let path = extract_module_path(file, base, "darkone.");
        assert_eq!(path, "darkone.service.adguardhome");
    }

    #[test]
    fn flat_options() {
        let src = r#"
{ lib, ... }: {
  options = {
    darkone.foo.enable = lib.mkEnableOption "Enable foo";
    darkone.foo.bar = lib.mkOption {
      type = lib.types.str;
      default = "hello";
      description = "Bar value";
    };
  };
}
"#;
        let opts = parse_module_options(src);
        assert_eq!(opts.len(), 2);
        assert_eq!(opts[0].name, "enable");
        assert_eq!(opts[0].type_label, "bool");
        assert_eq!(opts[1].name, "bar");
        assert_eq!(opts[1].type_label, "str");
        assert_eq!(opts[1].default.as_deref(), Some("\"hello\""));
        assert_eq!(opts[1].description.as_deref(), Some("Bar value"));
    }

    #[test]
    fn submodule_options() {
        let src = r#"
{ lib, ... }: {
  options = {
    darkone.x.enable = lib.mkEnableOption "Enable";
    darkone.x.service = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule (_: {
        options = {
          enable = lib.mkEnableOption "Inner";
          inner.deep = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Deep";
          };
        };
      }));
      description = "Services";
    };
  };
}
"#;
        let opts = parse_module_options(src);
        let names: Vec<_> = opts.iter().map(|o| (o.level, o.name.clone())).collect();
        assert_eq!(
            names,
            vec![
                (1, "enable".into()),
                (1, "service".into()),
                (2, "enable".into()),
                (2, "inner.deep".into()),
            ]
        );
        assert_eq!(opts[1].type_label, "attrs");
        assert_eq!(opts[1].default.as_deref(), Some("{ }"));
    }

    #[test]
    fn list_default_overridden() {
        let src = r#"
{ lib, ... }: {
  options = {
    darkone.x.things = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "a" ];
      description = "Things";
    };
  };
}
"#;
        let opts = parse_module_options(src);
        assert_eq!(opts[0].type_label, "listOf str");
        assert_eq!(opts[0].default.as_deref(), Some("[ ]"));
    }
}
