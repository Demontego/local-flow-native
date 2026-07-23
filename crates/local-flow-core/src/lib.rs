//! Local Flow shared engine: session FSM + ASR + LLM cleanup.

pub mod asr;
pub mod cleanup;
pub mod config;
pub mod context;
pub mod error;
pub mod history;
pub mod hub;
pub mod learn;
pub mod models;
pub mod personalization;
pub mod session;

pub use asr::AsrEngine;
pub use cleanup::CleanupEngine;
pub use config::EngineConfig;
pub use context::DictationContext;
pub use error::{Error, Result};
pub use hub::DictationDestination;
pub use session::{Engine, SessionPhase, SessionResult};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
