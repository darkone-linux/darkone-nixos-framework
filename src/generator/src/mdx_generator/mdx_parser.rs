use std::path::{Path, PathBuf};

use rnix::SyntaxKind;

#[derive(Debug, Clone)]
pub struct ModuleOption {
    pub name: String,
    pub option_type: Option<String>,
    pub default: Option<String>,
    pub example: Option<String>,
    pub description: Option<String>,
    pub is_enable: bool,
}

/// Extract the first comment block from a Nix source file.
pub fn extract_first_comment(source: &str) -> Option<String> {
    let parsed = rnix::Root::parse(source);
    let root = parsed.syntax();
    for node_or_token in root.children_with_tokens() {
        match node_or_token {
            rnix::NodeOrToken::Token(tok) if tok.kind() == SyntaxKind::TOKEN_COMMENT => {
                let text = tok.text().to_string();
                // Strip leading "#" and whitespace
                let cleaned = text
                    .lines()
                    .map(|l| l.trim_start_matches('#').trim().to_string())
                    .filter(|l| !l.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ");
                if !cleaned.is_empty() {
                    return Some(cleaned);
                }
            }
            rnix::NodeOrToken::Token(tok) if tok.kind() == SyntaxKind::TOKEN_WHITESPACE => {
                continue;
            }
            _ => break,
        }
    }
    None
}

/// Convert a file path relative to a base dir into a dotted module path.
/// e.g. "dnf/modules/standard/service/adguardhome.nix" -> "adguardhome"
pub fn extract_module_path(file: &Path, base: &Path, prefix: &str) -> String {
    let rel = file.strip_prefix(base).unwrap_or(file);
    let without_ext = rel.with_extension("");
    let parts: Vec<&str> = without_ext
        .components()
        .filter_map(|c| c.as_os_str().to_str())
        .collect();
    if parts.is_empty() {
        return prefix.to_string();
    }
    format!("{prefix}{}", parts.join("."))
}

/// Find all .nix files in a directory recursively, excluding default.nix.
pub fn extract_nix_files(dir: &Path) -> Vec<PathBuf> {
    let mut files = vec![];
    if !dir.exists() {
        return files;
    }
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                files.extend(extract_nix_files(&path));
            } else if path.extension().and_then(|e| e.to_str()) == Some("nix")
                && path.file_name().and_then(|n| n.to_str()) != Some("default.nix")
            {
                files.push(path);
            }
        }
    }
    files.sort();
    files
}

/// Parse a Nix source file and extract module option declarations.
/// Handles both `mkOption { ... }` and `mkEnableOption "desc"`.
pub fn extract_module_options(source: &str) -> Vec<ModuleOption> {
    let mut options = vec![];

    // We use line-based scanning as a pragmatic fallback since rnix's AST
    // traversal of deeply-nested option sets is complex.
    // rnix is used above for first-comment extraction.
    let mut lines = source.lines().peekable();
    while let Some(line) = lines.next() {
        let trimmed = line.trim();

        // mkEnableOption "description"
        if let Some(rest) = trimmed.strip_suffix(";").and_then(|l| {
            let i = l.find("mkEnableOption")?;
            Some(&l[i + "mkEnableOption".len()..])
        }) {
            let desc = rest.trim().trim_matches('"').to_string();
            let name = extract_option_name(trimmed);
            options.push(ModuleOption {
                name,
                option_type: Some("bool".to_string()),
                default: Some("false".to_string()),
                example: None,
                description: Some(desc),
                is_enable: true,
            });
            continue;
        }

        // mkOption {
        if trimmed.contains("mkOption") && trimmed.contains('{') {
            let name = extract_option_name(trimmed);
            let mut opt = ModuleOption {
                name,
                option_type: None,
                default: None,
                example: None,
                description: None,
                is_enable: false,
            };
            // Collect lines inside the mkOption block
            let mut depth = trimmed.chars().filter(|&c| c == '{').count() as i32
                - trimmed.chars().filter(|&c| c == '}').count() as i32;
            while depth > 0 {
                if let Some(inner) = lines.next() {
                    let inner_trim = inner.trim();
                    depth += inner_trim.chars().filter(|&c| c == '{').count() as i32;
                    depth -= inner_trim.chars().filter(|&c| c == '}').count() as i32;
                    if let Some(v) = parse_option_field(inner_trim, "type") {
                        opt.option_type = Some(v);
                    }
                    if let Some(v) = parse_option_field(inner_trim, "default") {
                        opt.default = Some(v);
                    }
                    if let Some(v) = parse_option_field(inner_trim, "example") {
                        opt.example = Some(v);
                    }
                    if let Some(v) = parse_option_field(inner_trim, "description") {
                        opt.description = Some(v);
                    }
                } else {
                    break;
                }
            }
            options.push(opt);
        }
    }

    options
}

fn extract_option_name(line: &str) -> String {
    if let Some(eq_pos) = line.find('=') {
        line[..eq_pos].trim().to_string()
    } else {
        line.to_string()
    }
}

fn parse_option_field(line: &str, field: &str) -> Option<String> {
    let prefix = format!("{field} =");
    let stripped = line.strip_prefix(&prefix)?.trim();
    let value = stripped.trim_end_matches(';').trim_matches('"').to_string();
    Some(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn extract_nix_files_excludes_default() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("default.nix"), "").unwrap();
        fs::write(dir.path().join("module.nix"), "").unwrap();
        let files = extract_nix_files(dir.path());
        assert_eq!(files.len(), 1);
        assert!(files[0].file_name().unwrap() == "module.nix");
    }

    #[test]
    fn extract_nix_files_recursive() {
        let dir = tempdir().unwrap();
        fs::create_dir(dir.path().join("sub")).unwrap();
        fs::write(dir.path().join("sub/foo.nix"), "").unwrap();
        let files = extract_nix_files(dir.path());
        assert_eq!(files.len(), 1);
    }

    #[test]
    fn extract_first_comment_basic() {
        let src = "# My module description\n{ config, lib, ... }:";
        let comment = extract_first_comment(src);
        assert!(comment.is_some());
        assert!(comment.unwrap().contains("My module description"));
    }

    #[test]
    fn extract_first_comment_none() {
        let src = "{ config, lib, ... }: {}";
        assert!(extract_first_comment(src).is_none());
    }

    #[test]
    fn extract_module_options_enable() {
        let src = r#"
            darkone.services.adguardhome.enable = mkEnableOption "AdGuard Home DNS";
        "#;
        let opts = extract_module_options(src);
        assert_eq!(opts.len(), 1);
        assert!(opts[0].is_enable);
        assert_eq!(opts[0].option_type.as_deref(), Some("bool"));
    }

    #[test]
    fn extract_module_options_mkoption() {
        let src = r#"
            darkone.services.adguardhome.port = mkOption {
              type = types.int;
              default = 3000;
              description = "Listening port";
            };
        "#;
        let opts = extract_module_options(src);
        assert_eq!(opts.len(), 1);
        assert_eq!(opts[0].option_type.as_deref(), Some("types.int"));
        assert_eq!(opts[0].default.as_deref(), Some("3000"));
    }

    #[test]
    fn module_path_extraction() {
        let base = Path::new("dnf/modules");
        let file = Path::new("dnf/modules/standard/service/adguardhome.nix");
        let path = extract_module_path(file, base, "darkone.");
        assert_eq!(path, "darkone.standard.service.adguardhome");
    }
}
