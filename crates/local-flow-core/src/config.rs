use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Paths and knobs for the shared engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineConfig {
    pub cache_dir: PathBuf,
    pub whisper_model: PathBuf,
    pub llm_model: PathBuf,
    pub sample_rate: u32,
    pub language: String,
    pub cleanup_prompt: String,
}

impl Default for EngineConfig {
    fn default() -> Self {
        let cache = default_cache_dir();
        let models = cache.join("models");
        Self {
            cache_dir: cache,
            whisper_model: models.join("ggml-small.bin"),
            llm_model: models.join(crate::models::LLM_FILENAME),
            sample_rate: 16_000,
            language: "ru".into(),
            cleanup_prompt: crate::cleanup::DEFAULT_PROMPT.to_string(),
        }
    }
}

pub fn default_cache_dir() -> PathBuf {
    dirs_next_home()
        .map(|h| h.join(".cache").join("local-flow-native"))
        .unwrap_or_else(|| PathBuf::from(".cache/local-flow-native"))
}

fn dirs_next_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

impl EngineConfig {
    /// Prefer existing Python Local Flow whisper if native path missing.
    pub fn resolve_whisper_path(&self) -> PathBuf {
        if self.whisper_model.exists() {
            return self.whisper_model.clone();
        }
        if let Some(home) = dirs_next_home() {
            let legacy = home
                .join(".cache")
                .join("local-flow")
                .join("models")
                .join("ggml-small.bin");
            if legacy.exists() {
                return legacy;
            }
        }
        self.whisper_model.clone()
    }
}
