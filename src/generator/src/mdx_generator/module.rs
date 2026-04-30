use std::path::Path;

use crate::mdx_generator::mdx_parser::{
    ModuleOption, extract_first_comment, extract_module_options, extract_module_path,
    extract_nix_files,
};

pub struct ModuleDoc {
    pub path: String,
    pub description: Option<String>,
    pub options: Vec<ModuleOption>,
    pub source_file: String,
}

pub fn scan_modules(dir: &Path, prefix: &str) -> Vec<ModuleDoc> {
    let mut docs = vec![];
    for file in extract_nix_files(dir) {
        let source = match std::fs::read_to_string(&file) {
            Ok(s) => s,
            Err(_) => continue,
        };
        let path = extract_module_path(&file, dir, prefix);
        let description = extract_first_comment(&source);
        let options = extract_module_options(&source);

        // Skip modules with no options
        if options.is_empty() && description.is_none() {
            continue;
        }

        docs.push(ModuleDoc {
            path,
            description,
            options,
            source_file: file.to_string_lossy().to_string(),
        });
    }
    docs.sort_by(|a, b| a.path.cmp(&b.path));
    docs
}

pub fn generate_mdx(project_root: &Path) -> String {
    let scan_dirs = [
        (project_root.join("dnf/modules/mixin"), "darkone."),
        (project_root.join("dnf/modules/standard"), "darkone."),
        (project_root.join("dnf/home/modules"), "darkone.home."),
    ];

    let mut all_docs: Vec<ModuleDoc> = vec![];
    for (dir, prefix) in &scan_dirs {
        all_docs.extend(scan_modules(dir, prefix));
    }

    let mut out = String::new();
    out.push_str("---\ntitle: Module Reference\n---\n\n");
    out.push_str("# DNF Module Reference\n\n");
    out.push_str("This page is auto-generated from the module source files.\n\n");

    for doc in &all_docs {
        out.push_str(&format!("## `{}`\n\n", doc.path));
        if let Some(desc) = &doc.description {
            out.push_str(&format!("{desc}\n\n"));
        }
        if !doc.options.is_empty() {
            out.push_str("| Option | Type | Default | Description |\n");
            out.push_str("|--------|------|---------|-------------|\n");
            for opt in &doc.options {
                let type_str = opt.option_type.as_deref().unwrap_or("-");
                let default_str = opt.default.as_deref().unwrap_or("-");
                let desc_str = opt.description.as_deref().unwrap_or("-");
                out.push_str(&format!(
                    "| `{}` | {} | `{}` | {} |\n",
                    opt.name, type_str, default_str, desc_str
                ));
            }
            out.push('\n');
        }
    }

    out
}
