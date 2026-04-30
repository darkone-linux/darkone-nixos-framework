use thiserror::Error;

#[derive(Error, Debug)]
pub enum NixError {
    #[error("{0}")]
    Validation(String),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("YAML error: {0}")]
    Yaml(#[from] serde_yaml::Error),

    #[error("Generator error: {0}")]
    Generate(String),
}

pub type Result<T> = std::result::Result<T, NixError>;

impl NixError {
    pub fn validation(msg: impl Into<String>) -> Self {
        Self::Validation(msg.into())
    }

    pub fn generate(msg: impl Into<String>) -> Self {
        Self::Generate(msg.into())
    }
}
