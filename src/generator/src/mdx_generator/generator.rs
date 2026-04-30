use std::path::Path;

use crate::error::Result;
use crate::mdx_generator::module::generate_mdx;

const OUTPUT_PATH: &str = "doc/src/content/docs/en/ref/modules.mdx";

pub fn generate(project_root: &Path, display: bool) -> Result<String> {
    let content = generate_mdx(project_root);
    if display {
        return Ok(content);
    }
    let target = project_root.join(OUTPUT_PATH);
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&target, &content)?;
    Ok(String::new())
}
