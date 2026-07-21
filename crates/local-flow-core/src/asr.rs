use crate::error::{Error, Result};
use std::path::Path;
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq)]
pub struct Transcription {
    pub text: String,
    /// Mean probability of Whisper's decoded text tokens, when the backend exposes it.
    pub mean_token_probability: Option<f32>,
}

pub trait AsrBackend: Send + Sync {
    fn transcribe(
        &self,
        pcm_f32: &[f32],
        language: &str,
        initial_prompt: Option<&str>,
        beam_size: usize,
    ) -> Result<Transcription>;
}

/// Echo backend for tests / missing models.
pub struct StubAsr;

impl AsrBackend for StubAsr {
    fn transcribe(
        &self,
        _pcm_f32: &[f32],
        _language: &str,
        _initial_prompt: Option<&str>,
        _beam_size: usize,
    ) -> Result<Transcription> {
        Ok(Transcription {
            text: String::new(),
            mean_token_probability: None,
        })
    }
}

pub struct AsrEngine {
    inner: Arc<dyn AsrBackend>,
    pub backend_name: String,
}

impl AsrEngine {
    pub fn stub() -> Self {
        Self {
            inner: Arc::new(StubAsr),
            backend_name: "stub".into(),
        }
    }

    pub fn load(model: &Path) -> Result<Self> {
        if !model.exists() {
            return Err(Error::ModelMissing(model.display().to_string()));
        }
        #[cfg(feature = "whisper")]
        {
            return Ok(Self {
                inner: Arc::new(whisper_backend::WhisperAsr::load(model)?),
                backend_name: "whisper".into(),
            });
        }
        #[cfg(not(feature = "whisper"))]
        {
            Err(Error::msg("whisper feature disabled at build time"))
        }
    }

    pub fn transcribe(
        &self,
        pcm_f32: &[f32],
        language: &str,
        initial_prompt: Option<&str>,
        beam_size: usize,
    ) -> Result<Transcription> {
        // whisper.cpp rejects clips < 1000 ms
        let min_len = 16_000; // 1.0 s @ 16 kHz
        let pcm: Vec<f32> = if pcm_f32.len() < min_len {
            let mut v = pcm_f32.to_vec();
            v.resize(min_len, 0.0);
            v
        } else {
            pcm_f32.to_vec()
        };
        self.inner
            .transcribe(&pcm, language, initial_prompt, beam_size)
            .map(|mut result| {
                result.text = result.text.trim().to_string();
                result
            })
    }
}

#[cfg(feature = "whisper")]
mod whisper_backend {
    use super::*;
    use parking_lot::Mutex;
    use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

    pub struct WhisperAsr {
        ctx: Mutex<WhisperContext>,
    }

    impl WhisperAsr {
        pub fn load(model: &Path) -> Result<Self> {
            let ctx = WhisperContext::new_with_params(
                model
                    .to_str()
                    .ok_or_else(|| Error::msg("non-utf8 model path"))?,
                WhisperContextParameters::default(),
            )
            .map_err(|e| Error::Asr(format!("load whisper: {e}")))?;
            Ok(Self {
                ctx: Mutex::new(ctx),
            })
        }
    }

    impl AsrBackend for WhisperAsr {
        fn transcribe(
            &self,
            pcm_f32: &[f32],
            language: &str,
            initial_prompt: Option<&str>,
            beam_size: usize,
        ) -> Result<Transcription> {
            let ctx = self.ctx.lock();
            let mut state = ctx
                .create_state()
                .map_err(|e| Error::Asr(format!("state: {e}")))?;
            let strategy = if beam_size > 1 {
                SamplingStrategy::BeamSearch {
                    beam_size: beam_size as i32,
                    patience: 1.0,
                }
            } else {
                SamplingStrategy::Greedy { best_of: 1 }
            };
            let mut params = FullParams::new(strategy);
            params.set_language(Some(language));
            params.set_print_special(false);
            params.set_print_progress(false);
            params.set_print_realtime(false);
            params.set_print_timestamps(false);
            if let Some(p) = initial_prompt {
                params.set_initial_prompt(p);
            }
            state
                .full(params, pcm_f32)
                .map_err(|e| Error::Asr(format!("full: {e}")))?;
            let n = state.full_n_segments();
            let mut out = String::new();
            let mut probability_sum = 0.0;
            let mut probability_count = 0_u32;
            for i in 0..n {
                let segment = state
                    .get_segment(i)
                    .ok_or_else(|| Error::Asr(format!("segment {i} out of bounds")))?;
                let seg = segment
                    .to_str()
                    .map_err(|e| Error::Asr(format!("segment: {e}")))?;
                if !out.is_empty() {
                    out.push(' ');
                }
                out.push_str(seg.trim());
                let mut token = 0;
                while let Some(token_info) = segment.get_token(token) {
                    let probability = token_info.token_probability();
                    if probability.is_finite() {
                        probability_sum += probability;
                        probability_count += 1;
                    }
                    token += 1;
                }
            }
            Ok(Transcription {
                text: out,
                mean_token_probability: (probability_count > 0)
                    .then(|| probability_sum / probability_count as f32),
            })
        }
    }
}
