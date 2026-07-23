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

    /// Non-blocking path for live partials. `None` = busy, skip this tick.
    fn try_transcribe(
        &self,
        pcm_f32: &[f32],
        language: &str,
        initial_prompt: Option<&str>,
        beam_size: usize,
    ) -> Result<Option<Transcription>> {
        self.transcribe(pcm_f32, language, initial_prompt, beam_size)
            .map(Some)
    }
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
        // whisper.cpp wants ≥1s. Never pad with silence — that hallucinates
        // `[музыка]` / `*name*` and live-typing pastes the junk into the field.
        let min_len = 16_000; // 1.0 s @ 16 kHz
        if pcm_f32.len() < min_len {
            return Ok(Transcription {
                text: String::new(),
                mean_token_probability: None,
            });
        }
        self.inner
            .transcribe(pcm_f32, language, initial_prompt, beam_size)
            .map(|mut result| {
                result.text = sanitize_asr_text(&result.text);
                result
            })
    }

    /// Live partial: skip if Whisper still running (turbo is too slow to queue).
    pub fn try_transcribe(
        &self,
        pcm_f32: &[f32],
        language: &str,
        initial_prompt: Option<&str>,
        beam_size: usize,
    ) -> Result<Option<Transcription>> {
        let min_len = 16_000;
        if pcm_f32.len() < min_len {
            return Ok(Some(Transcription {
                text: String::new(),
                mean_token_probability: None,
            }));
        }
        Ok(match self
            .inner
            .try_transcribe(pcm_f32, language, initial_prompt, beam_size)?
        {
            None => None,
            Some(mut result) => {
                result.text = sanitize_asr_text(&result.text);
                Some(result)
            }
        })
    }
}

/// Drop Whisper no-speech / music tags that leak into the transcript.
pub fn sanitize_asr_text(text: &str) -> String {
    let t = text.trim();
    if t.is_empty() {
        return String::new();
    }
    let lower = t.to_lowercase();
    if matches!(
        lower.as_str(),
        "[музыка]"
            | "[music]"
            | "(music)"
            | "[тишина]"
            | "[silence]"
            | "[blank_audio]"
            | "[пусто]"
            | "(тишина)"
    ) {
        return String::new();
    }
    // Whole bracket/paren tag, or lone *token* hallucination.
    let bracketed = (t.starts_with('[') && t.ends_with(']'))
        || (t.starts_with('(') && t.ends_with(')') && t.len() < 48);
    let starred = t.starts_with('*')
        && t.ends_with('*')
        && t.len() < 40
        && !t[1..t.len() - 1].contains(char::is_whitespace);
    if bracketed || starred {
        return String::new();
    }
    t.to_string()
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
            let mut ctx_params = WhisperContextParameters::default();
            // Metal can return full() Ok with 0 segments (silent empty). base-ru
            // is small enough that CPU is fast and reliable on Apple silicon.
            ctx_params.use_gpu(false);
            ctx_params.flash_attn(false);
            let ctx = WhisperContext::new_with_params(
                model
                    .to_str()
                    .ok_or_else(|| Error::msg("non-utf8 model path"))?,
                ctx_params,
            )
            .map_err(|e| Error::Asr(format!("load whisper: {e}")))?;
            Ok(Self {
                ctx: Mutex::new(ctx),
            })
        }
    }

    fn run_full(
        ctx: &WhisperContext,
        pcm_f32: &[f32],
        language: &str,
        initial_prompt: Option<&str>,
        beam_size: usize,
    ) -> Result<Transcription> {
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
        let n_threads = std::thread::available_parallelism()
            .map(|n| n.get() as i32)
            .unwrap_or(4)
            .clamp(1, 8);
        params.set_n_threads(n_threads);
        params.set_language(Some(language));
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_suppress_blank(true);
        params.set_suppress_nst(true);
        // Short push-to-talk clips — skip decoder context carry / multi-segment overhead.
        params.set_no_context(true);
        params.set_single_segment(true);
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
            // Skip near-silence segments (music / blank hallucinations).
            if segment.no_speech_probability() > 0.6 {
                continue;
            }
            let seg = segment
                .to_str()
                .map_err(|e| Error::Asr(format!("segment: {e}")))?;
            let seg = sanitize_asr_text(seg);
            if seg.is_empty() {
                continue;
            }
            if !out.is_empty() {
                out.push(' ');
            }
            out.push_str(&seg);
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

    impl AsrBackend for WhisperAsr {
        fn transcribe(
            &self,
            pcm_f32: &[f32],
            language: &str,
            initial_prompt: Option<&str>,
            beam_size: usize,
        ) -> Result<Transcription> {
            let ctx = self.ctx.lock();
            run_full(&ctx, pcm_f32, language, initial_prompt, beam_size)
        }

        fn try_transcribe(
            &self,
            pcm_f32: &[f32],
            language: &str,
            initial_prompt: Option<&str>,
            beam_size: usize,
        ) -> Result<Option<Transcription>> {
            let Some(ctx) = self.ctx.try_lock() else {
                return Ok(None);
            };
            Ok(Some(run_full(
                &ctx,
                pcm_f32,
                language,
                initial_prompt,
                beam_size,
            )?))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::sanitize_asr_text;

    #[test]
    fn drops_whisper_silence_hallucinations() {
        assert_eq!(sanitize_asr_text("[музыка]"), "");
        assert_eq!(sanitize_asr_text("*Джейсон*"), "");
        assert_eq!(sanitize_asr_text("(music)"), "");
        assert_eq!(sanitize_asr_text("  привет мир  "), "привет мир");
        assert_eq!(sanitize_asr_text("1,2,3,4,5"), "1,2,3,4,5");
    }
}
