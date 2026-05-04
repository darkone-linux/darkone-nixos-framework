//! Modules reference page (`doc/src/content/docs/en/ref/modules.mdx`).
//!
//! Specific to the modules.mdx layout — generic Nix/MDX primitives live in
//! `nix_parser` and `mdx_writer`.

use std::path::{Path, PathBuf};

use crate::mdx_generator::mdx_writer::escape;
use crate::mdx_generator::nix_parser::{
    extract_first_comment, extract_module_path, extract_nix_files, parse_module_options, NixOption,
};

const FRONTMATTER: &str =
    "---\ntitle: Modules\nsidebar:\n  order: 1\n  badge:\n    text: New\n    variant: tip\n---\n";

struct Category {
    title: &'static str,
    description: &'static str,
    relative_dir: &'static str,
    prefix: &'static str,
    icon: &'static str,
}

const CATEGORIES: &[Category] = &[
    Category {
        title: "Mixin modules",
        description: "**A mixin module** defines a collection of standard modules with a consistent common configuration.",
        relative_dir: "dnf/modules/mixin",
        prefix: "darkone.",
        icon: "&#x1F4E6;",
    },
    Category {
        title: "Standard modules",
        description: "**A standard module** contains auto-configured features.",
        relative_dir: "dnf/modules/standard",
        prefix: "darkone.",
        icon: "&#x1F48E;",
    },
    Category {
        title: "Home Manager modules",
        description: "**A home manager module** works with [home manager](https://github.com/nix-community/home-manager) profiles.",
        relative_dir: "dnf/home/modules",
        prefix: "darkone.home.",
        icon: "&#x1F3E0;",
    },
];

struct ModuleEntry {
    path: String,
    comment: Option<String>,
    options: Vec<NixOption>,
}

/// Build the full `modules.mdx` content for `project_root`.
pub fn generate_mdx(project_root: &Path) -> String {
    let mut sections: Vec<String> = vec![];
    for category in CATEGORIES {
        let dir = project_root.join(category.relative_dir);
        sections.push(render_category(category, &dir));
    }
    format!("{FRONTMATTER}\n{}", sections.join("\n\n"))
}

fn render_category(category: &Category, dir: &Path) -> String {
    let mut out = String::new();
    out.push_str(&format!("## {}\n\n", category.title));
    out.push_str(&format!(":::note\n{}\n:::\n\n", category.description));
    for entry in collect_entries(dir, category.prefix) {
        out.push_str(&render_module(&entry, category.icon));
    }
    out
}

// Collect nix modules contents
fn collect_entries(dir: &Path, prefix: &str) -> Vec<ModuleEntry> {
    let files: Vec<PathBuf> = extract_nix_files(dir);
    let mut entries = vec![];
    for file in files {
        let Ok(source) = std::fs::read_to_string(&file) else {
            continue;
        };
        entries.push(ModuleEntry {
            path: extract_module_path(&file, dir, prefix),
            comment: extract_first_comment(&source),
            options: parse_module_options(&source),
        });
    }
    entries
}

fn render_module(entry: &ModuleEntry, icon: &str) -> String {
    let mut out = String::new();
    out.push_str(&format!("### {icon} {}\n\n", entry.path));
    if let Some(c) = &entry.comment {
        out.push_str(c);
        out.push_str("\n\n");
    }
    out.push_str(&render_options(entry));
    out.push_str("<hr/>\n\n");
    out
}

fn render_options(entry: &ModuleEntry) -> String {
    if entry.options.is_empty() {
        return String::new();
    }
    let mut bullets = String::new();
    let mut code = String::new();
    let opt_count = entry.options.len();
    let multi = opt_count > 1;

    code.push_str("\n```nix\n");
    if multi {
        code.push_str(&format!("{} = {{\n", entry.path));
    }

    let prefix = if multi {
        "  ".to_string()
    } else {
        format!("{}.", entry.path)
    };

    // Track names by level so we can rebuild dotted paths inside opened submodules.
    let mut opened_levels: Vec<String> = vec![];
    let mut last_level = 1usize;
    let mut names_by_level: Vec<String> = vec![String::new()];

    for (i, opt) in entry.options.iter().enumerate() {
        // Adjust the stack of "opened" parent names.
        if opt.level > last_level {
            // Diving in: the previous option's name becomes a parent dotted prefix.
            while opened_levels.len() < opt.level - 1 {
                let idx = opened_levels.len() + 1;
                let parent = names_by_level.get(idx).cloned().unwrap_or_default();
                opened_levels.push(parent);
            }
        } else if opt.level <= last_level {
            // Coming back out (or staying flat): drop deeper parents.
            opened_levels.truncate(opt.level - 1);
        }

        // Remember this option's name at its level (parents may use it later).
        while names_by_level.len() <= opt.level {
            names_by_level.push(String::new());
        }
        names_by_level[opt.level] = opt.name.clone();

        let indent = "  ".repeat(opt.level - 1);
        bullets.push_str(&indent);
        bullets.push_str("* **");
        bullets.push_str(&escape(&opt.name));
        bullets.push_str("**");
        if !opt.type_label.is_empty() {
            bullets.push_str(&format!(" `{}`", opt.type_label));
        }
        if let Some(desc) = &opt.description {
            let trimmed = desc.trim().trim_matches('"');
            if !trimmed.is_empty() {
                bullets.push(' ');
                bullets.push_str(&escape(trimmed));
            }
        }
        bullets.push('\n');

        // Skip emitting `parent = { };` when its submodule body follows.
        let opens_submodule = matches!(opt.type_label.as_str(), "submodule" | "attrs");
        let next_is_deeper = entry
            .options
            .get(i + 1)
            .map(|n| n.level > opt.level)
            .unwrap_or(false);
        if opens_submodule && next_is_deeper {
            last_level = opt.level;
            continue;
        }

        let value = code_value(opt);
        let parents = opened_levels
            .iter()
            .map(|p| format!("{p}."))
            .collect::<String>();
        code.push_str(&prefix);
        code.push_str(&parents);
        code.push_str(&opt.name);
        code.push_str(" = ");
        code.push_str(&value);
        code.push_str(";\n");

        last_level = opt.level;
    }

    if multi {
        code.push_str("};\n");
    }
    code.push_str("```\n\n");

    format!("{bullets}{code}")
}

fn code_value(opt: &NixOption) -> String {
    if let Some(ex) = &opt.example {
        if !ex.is_empty() {
            return ex.clone();
        }
    }
    if let Some(d) = &opt.default {
        if !d.is_empty() {
            return d.clone();
        }
    }
    "null".into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn renders_simple_module() {
        let dir = tempdir().unwrap();
        let dnf = dir.path().join("dnf/modules/standard/service");
        fs::create_dir_all(&dnf).unwrap();
        fs::write(
            dnf.join("foo.nix"),
            r#"# A foo service.
{ lib, ... }: {
  options = {
    darkone.service.foo.enable = lib.mkEnableOption "Enable foo";
  };
}
"#,
        )
        .unwrap();

        let mdx = generate_mdx(dir.path());
        assert!(mdx.contains("### &#x1F48E; darkone.service.foo"));
        assert!(mdx.contains("A foo service."));
        assert!(mdx.contains("* **enable** `bool` Enable foo"));
        assert!(mdx.contains("darkone.service.foo.enable = false;"));
    }

    #[test]
    fn renders_submodule_block() {
        let dir = tempdir().unwrap();
        let dnf = dir.path().join("dnf/modules/standard/system");
        fs::create_dir_all(&dnf).unwrap();
        fs::write(
            dnf.join("services.nix"),
            r#"{ lib, ... }: {
  options = {
    darkone.system.services.enable = lib.mkEnableOption "Enable manager";
    darkone.system.services.service = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule (_: {
        options = {
          enable = lib.mkEnableOption "Enable proxy";
          persist.dirs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Dirs";
          };
        };
      }));
      description = "Services";
    };
  };
}
"#,
        )
        .unwrap();

        let mdx = generate_mdx(dir.path());
        assert!(mdx.contains("* **service** `attrs` Services"));
        assert!(mdx.contains("  * **enable** `bool` Enable proxy"));
        assert!(mdx.contains("  * **persist.dirs** `listOf str` Dirs"));
        // Inside multi-option, nested code uses parent dotted prefix:
        assert!(mdx.contains("service.enable = false;"));
        assert!(mdx.contains("service.persist.dirs = [ ];"));
    }
}
