uniffi::setup_scaffolding!();

pub mod c_api;

use local_flow_core::config::EngineConfig;
use local_flow_core::context::DictationContext;
use local_flow_core::session::Engine;
use parking_lot::Mutex;
use std::sync::Arc;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FlowError {
    #[error("{msg}")]
    Message { msg: String },
}

impl From<local_flow_core::Error> for FlowError {
    fn from(e: local_flow_core::Error) -> Self {
        Self::Message {
            msg: e.to_string(),
        }
    }
}

#[uniffi::export]
pub fn library_version() -> String {
    local_flow_core::VERSION.to_string()
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiContext {
    pub app_name: String,
    pub bundle_id: String,
    pub channel_hint: String,
    pub before_text: String,
    pub selected_text: String,
    pub chat_lines: Vec<String>,
    pub recent: Vec<String>,
    pub screenshot_path: Option<String>,
}

impl From<FfiContext> for DictationContext {
    fn from(c: FfiContext) -> Self {
        DictationContext {
            app_name: c.app_name,
            bundle_id: c.bundle_id,
            channel_hint: c.channel_hint,
            before_text: c.before_text,
            selected_text: c.selected_text,
            chat_lines: c.chat_lines,
            recent: c.recent,
            screenshot_path: c.screenshot_path,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiModelsStatus {
    pub whisper: bool,
    pub llm: bool,
    pub whisper_path: String,
    pub llm_path: String,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiSessionResult {
    pub raw: String,
    pub clean: String,
}

#[derive(uniffi::Object)]
pub struct LocalFlowEngine {
    inner: Engine,
    summary: Mutex<String>,
}

#[uniffi::export]
impl LocalFlowEngine {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Engine::new(EngineConfig::default()),
            summary: Mutex::new(String::new()),
        })
    }

    pub fn models_status(&self) -> FfiModelsStatus {
        let s = self.inner.models_status();
        FfiModelsStatus {
            whisper: s.whisper,
            llm: s.llm,
            whisper_path: s.whisper_path,
            llm_path: s.llm_path,
        }
    }

    pub fn load_models(&self) -> Result<String, FlowError> {
        let s = self.inner.load_models()?;
        *self.summary.lock() = s.clone();
        Ok(s)
    }

    pub fn download_whisper(&self) -> Result<String, FlowError> {
        Ok(self.inner.download_whisper(|_| {})?)
    }

    pub fn download_qwen(&self) -> Result<String, FlowError> {
        Ok(self.inner.download_qwen(|_| {})?)
    }

    pub fn start_hold(&self) -> Result<(), FlowError> {
        Ok(self.inner.start_hold()?)
    }

    pub fn push_audio(&self, samples: Vec<f32>) -> Result<(), FlowError> {
        Ok(self.inner.push_audio(&samples)?)
    }

    pub fn partial_transcript(&self) -> Result<String, FlowError> {
        Ok(self.inner.partial_transcript()?)
    }

    pub fn end_hold(&self, ctx: FfiContext) -> Result<FfiSessionResult, FlowError> {
        let r = self.inner.end_hold(ctx.into())?;
        Ok(FfiSessionResult {
            raw: r.raw,
            clean: r.clean,
        })
    }

    pub fn cancel_hold(&self) {
        self.inner.cancel_hold();
    }

    pub fn cleanup_text(&self, raw: String, ctx: FfiContext) -> Result<String, FlowError> {
        Ok(self.inner.cleanup_text(&raw, &ctx.into())?)
    }

    pub fn backend_summary(&self) -> String {
        self.summary.lock().clone()
    }
}

impl LocalFlowEngine {
    /// C ABI: download with percent callback 0..=100 (not exported via UniFFI).
    pub fn download_whisper_with_progress(
        &self,
        mut on_progress: impl FnMut(u32),
    ) -> Result<String, FlowError> {
        Ok(self.inner.download_whisper(&mut on_progress)?)
    }

    pub fn download_qwen_with_progress(
        &self,
        mut on_progress: impl FnMut(u32),
    ) -> Result<String, FlowError> {
        Ok(self.inner.download_qwen(&mut on_progress)?)
    }
}
