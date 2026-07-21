use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Paths and knobs for the shared engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineConfig {
    /// Platform sandbox owned by the calling shell.
    pub data_dir: PathBuf,
    pub whisper_model: PathBuf,
    pub llm_model: PathBuf,
    pub sample_rate: u32,
    pub language: String,
    pub cleanup_prompt: String,
}

impl EngineConfig {
    /// The host must provide its application-data sandbox. The core never
    /// consults HOME, XDG, or a working-directory cache.
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        let data_dir = data_dir.into();
        let models = data_dir.join("models");
        Self {
            data_dir,
            whisper_model: models.join("ggml-small.bin"),
            llm_model: models.join(crate::models::LLM_FILENAME),
            sample_rate: 16_000,
            language: "ru".into(),
            cleanup_prompt: crate::cleanup::DEFAULT_PROMPT.to_string(),
        }
    }

    pub fn resolve_whisper_path(&self) -> PathBuf {
        self.whisper_model.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::EngineConfig;
    use std::path::Path;

    #[test]
    fn model_paths_stay_inside_shell_data_dir() {
        let config = EngineConfig::new("shell-data");
        assert_eq!(
            config.whisper_model,
            Path::new("shell-data/models/ggml-small.bin")
        );
        assert_eq!(
            config.llm_model,
            Path::new("shell-data/models/Qwen3-1.7B-Q4_K_M.gguf")
        );
    }
}
