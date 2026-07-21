use crate::asr::AsrEngine;
use crate::cleanup::CleanupEngine;
use crate::config::EngineConfig;
use crate::context::DictationContext;
use crate::error::{Error, Result};
use crate::history;
use crate::models::{self, ModelsStatus};
use crate::personalization;
use parking_lot::Mutex;
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionPhase {
    Idle,
    Listening,
    Transcribing,
    Cleaning,
}

#[derive(Debug, Clone)]
pub struct SessionResult {
    pub raw: String,
    pub clean: String,
    pub asr_confidence: Option<f32>,
    pub press_enter: bool,
    pub phase: SessionPhase,
}

/// Shared engine used by all platform shells via FFI.
pub struct Engine {
    cfg: EngineConfig,
    asr: Mutex<Option<AsrEngine>>,
    cleanup: Mutex<Option<CleanupEngine>>,
    phase: Mutex<SessionPhase>,
    pcm: Mutex<Vec<f32>>,
    /// Serialize model loads (boot + menu "Load models" race → heuristic overwrite).
    load_lock: Mutex<()>,
}

impl Engine {
    pub fn new(cfg: EngineConfig) -> Self {
        Self {
            cfg,
            asr: Mutex::new(None),
            cleanup: Mutex::new(None),
            phase: Mutex::new(SessionPhase::Idle),
            pcm: Mutex::new(Vec::new()),
            load_lock: Mutex::new(()),
        }
    }

    pub fn version() -> &'static str {
        crate::VERSION
    }

    pub fn config(&self) -> &EngineConfig {
        &self.cfg
    }

    pub fn models_status(&self) -> ModelsStatus {
        models::status(&self.cfg)
    }

    pub fn load_models(&self) -> Result<String> {
        let _gate = self.load_lock.lock();
        let whisper_path = self.cfg.resolve_whisper_path();
        let (asr, asr_note) = match AsrEngine::load(&whisper_path) {
            Ok(a) => (a, None),
            Err(e) => {
                tracing::warn!("whisper load failed, stub: {e}");
                (AsrEngine::stub(), Some(format!("whisper_err={e}")))
            }
        };
        let (cleanup, llm_note) =
            match CleanupEngine::load(&self.cfg.llm_model, &self.cfg.cleanup_prompt) {
                Ok(c) => (c, None),
                Err(e) => {
                    tracing::warn!("llm load failed, heuristic: {e}");
                    // Keep a previously loaded Qwen if reload failed (e.g. race).
                    if let Some(prev) = self.cleanup.lock().as_ref() {
                        if prev.backend_name == "qwen3" {
                            let summary = format!(
                                "asr={} cleanup=qwen3 (reload skipped: {e})",
                                asr.backend_name
                            );
                            *self.asr.lock() = Some(asr);
                            return Ok(summary);
                        }
                    }
                    (CleanupEngine::heuristic(), Some(format!("llm_err={e}")))
                }
            };
        let mut summary = format!("asr={} cleanup={}", asr.backend_name, cleanup.backend_name);
        if let Some(n) = asr_note {
            summary.push(' ');
            summary.push_str(&n);
        }
        if let Some(n) = llm_note {
            summary.push(' ');
            summary.push_str(&n);
        }
        *self.asr.lock() = Some(asr);
        *self.cleanup.lock() = Some(cleanup);
        Ok(summary)
    }

    pub fn download_whisper(&self, on_progress: impl FnMut(u32)) -> Result<String> {
        let r = models::download_whisper(&self.cfg, on_progress)?;
        Ok(r.to_wire())
    }

    pub fn download_qwen(&self, on_progress: impl FnMut(u32)) -> Result<String> {
        let r = models::download_qwen(&self.cfg, on_progress)?;
        Ok(r.to_wire())
    }

    pub fn start_hold(&self) -> Result<()> {
        let mut phase = self.phase.lock();
        if *phase != SessionPhase::Idle {
            return Err(Error::InvalidState(format!("cannot start from {phase:?}")));
        }
        *phase = SessionPhase::Listening;
        self.pcm.lock().clear();
        Ok(())
    }

    pub fn push_audio(&self, samples: &[f32]) -> Result<()> {
        if *self.phase.lock() != SessionPhase::Listening {
            return Err(Error::InvalidState("not listening".into()));
        }
        self.pcm.lock().extend_from_slice(samples);
        Ok(())
    }

    pub fn partial_transcript(&self) -> Result<String> {
        let asr = self.asr.lock();
        let asr = asr.as_ref().ok_or(Error::ModelsNotLoaded)?;
        let pcm = self.pcm.lock();
        if pcm.len() < (self.cfg.sample_rate as usize / 4) {
            return Ok(String::new());
        }
        asr.transcribe(&pcm, &self.cfg.language, None, 1)
            .map(|result| result.text)
    }

    pub fn end_hold(&self, mut ctx: DictationContext) -> Result<SessionResult> {
        {
            let mut phase = self.phase.lock();
            if *phase != SessionPhase::Listening {
                return Err(Error::InvalidState(format!("cannot end from {phase:?}")));
            }
            *phase = SessionPhase::Transcribing;
        }

        let outcome = (|| -> Result<SessionResult> {
            let personalization = personalization::load(&self.cfg.data_dir);
            personalization::apply_context(&mut ctx, &personalization);
            if ctx.recent.is_empty() && !ctx.bundle_id.is_empty() {
                ctx.recent = history::load_recent(&self.cfg.data_dir, &ctx.bundle_id);
            }

            let pcm = std::mem::take(&mut *self.pcm.lock());
            let secs = pcm.len() as f32 / self.cfg.sample_rate as f32;
            let min = (self.cfg.sample_rate as f32 * 0.35) as usize;
            if pcm.len() < min {
                return Ok(SessionResult {
                    raw: format!("empty:audio={secs:.2}s (need ≥0.35s)"),
                    clean: String::new(),
                    asr_confidence: None,
                    press_enter: false,
                    phase: SessionPhase::Idle,
                });
            }

            let prompt = ctx.asr_initial_prompt();
            let transcription = {
                let asr = self.asr.lock();
                let asr = asr.as_ref().ok_or(Error::ModelsNotLoaded)?;
                asr.transcribe(&pcm, &self.cfg.language, prompt.as_deref(), 5)?
            };
            let raw = transcription.text;
            let asr_confidence = transcription.mean_token_probability;

            if raw.trim().is_empty() {
                return Ok(SessionResult {
                    raw: format!("empty:whisper audio={secs:.2}s"),
                    clean: String::new(),
                    asr_confidence,
                    press_enter: false,
                    phase: SessionPhase::Idle,
                });
            }

            *self.phase.lock() = SessionPhase::Cleaning;
            let (clean, cleanup_decision) = if personalization.cleanup_enabled {
                let cleanup = self.cleanup.lock();
                let cleanup = cleanup.as_ref().ok_or(Error::ModelsNotLoaded)?;
                match cleanup.cleanup(&raw, &ctx) {
                    Ok(candidate) if crate::cleanup::accepts_cleanup(&raw, &candidate, &ctx) => {
                        (candidate, "qwen")
                    }
                    Ok(candidate) => {
                        log_quality(
                            &self.cfg,
                            &raw,
                            &candidate,
                            "guarded fallback",
                            asr_confidence,
                        );
                        (
                            crate::cleanup::heuristic_polish(&raw, &ctx),
                            "guarded fallback",
                        )
                    }
                    Err(e) => {
                        tracing::warn!("cleanup failed, heuristic fallback: {e}");
                        (
                            crate::cleanup::heuristic_polish(&raw, &ctx),
                            "error fallback",
                        )
                    }
                }
            } else {
                (raw.clone(), "disabled")
            };
            let smart = crate::cleanup::smart_format(&clean);
            let clean = personalization::expand_snippets(
                &personalization::apply_replacements(&smart.text, &personalization),
                &personalization,
            );

            if !clean.is_empty() && !ctx.bundle_id.is_empty() {
                let _ = history::save_recent(&self.cfg.data_dir, &ctx.bundle_id, &clean);
            }
            log_quality(&self.cfg, &raw, &clean, cleanup_decision, asr_confidence);

            Ok(SessionResult {
                raw,
                clean,
                asr_confidence,
                press_enter: smart.press_enter,
                phase: SessionPhase::Idle,
            })
        })();

        // Always leave Listening/Transcribing so the next hold can start.
        *self.phase.lock() = SessionPhase::Idle;
        outcome
    }

    pub fn cancel_hold(&self) {
        self.pcm.lock().clear();
        *self.phase.lock() = SessionPhase::Idle;
    }

    pub fn phase(&self) -> SessionPhase {
        *self.phase.lock()
    }

    /// Cleanup-only API for shells that already have ASR text.
    pub fn cleanup_text(&self, raw: &str, ctx: &DictationContext) -> Result<String> {
        let cleanup = self.cleanup.lock();
        let cleanup = cleanup.as_ref().ok_or(Error::ModelsNotLoaded)?;
        cleanup.cleanup(raw, ctx)
    }

    pub fn personalization(&self) -> personalization::Personalization {
        personalization::load(&self.cfg.data_dir)
    }

    pub fn save_personalization(&self, settings: &personalization::Personalization) -> Result<()> {
        personalization::save(&self.cfg.data_dir, settings)
    }

    pub fn recent_for(&self, bundle_id: &str) -> Vec<String> {
        history::load_recent(&self.cfg.data_dir, bundle_id)
    }
}

fn log_quality(
    cfg: &EngineConfig,
    raw: &str,
    candidate: &str,
    decision: &str,
    confidence: Option<f32>,
) {
    fn cap(text: &str) -> String {
        let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
        let mut clipped: String = compact.chars().take(200).collect();
        if compact.chars().count() > clipped.chars().count() {
            clipped.push('…');
        }
        clipped.replace('"', "'")
    }

    let path = cfg.data_dir.join("paste.log");
    if std::fs::create_dir_all(&cfg.data_dir).is_err() {
        return;
    }
    let confidence = confidence
        .map(|value| format!("{value:.3}"))
        .unwrap_or_else(|| "n/a".into());
    let line = format!(
        "asr_quality confidence={confidence} decision={decision:?} raw_len={} candidate_len={} raw={:?} candidate={:?}\n",
        raw.chars().count(),
        candidate.chars().count(),
        cap(raw),
        cap(candidate),
    );
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = file.write_all(line.as_bytes());
    }
}

pub type SharedEngine = Arc<Engine>;
