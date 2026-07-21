use thiserror::Error;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Error)]
pub enum Error {
    #[error("{0}")]
    Message(String),
    #[error("models not loaded")]
    ModelsNotLoaded,
    #[error("model file missing: {0}")]
    ModelMissing(String),
    #[error("ASR error: {0}")]
    Asr(String),
    #[error("cleanup error: {0}")]
    Cleanup(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid state: {0}")]
    InvalidState(String),
}

impl Error {
    pub fn msg(s: impl Into<String>) -> Self {
        Self::Message(s.into())
    }
}
