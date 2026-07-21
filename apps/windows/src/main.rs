//! Windows tray shell — same `local-flow-core` session API as macOS.
//!
//! Hold Ctrl+Alt → speak → release → cleaned text pasted (clipboard + Ctrl+V).
//! Non-Windows hosts smoke-test the engine so macOS CI still validates the crate.

use local_flow_core::config::EngineConfig;
use local_flow_core::context::DictationContext;
use local_flow_core::session::Engine;
use std::path::PathBuf;

fn application_data_dir() -> PathBuf {
    #[cfg(windows)]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join("Local Flow Native")
    }
    #[cfg(not(windows))]
    {
        std::env::temp_dir().join("Local Flow Native")
    }
}

fn main() {
    tracing_subscriber::fmt::init();
    tracing::info!("local-flow-windows {}", Engine::version());

    #[cfg(not(windows))]
    {
        let eng = Engine::new(EngineConfig::new(application_data_dir()));
        let summary = eng.load_models().expect("load");
        println!(
            "engine ready ({summary}) — build on Windows with --features full for tray UI"
        );
        eng.start_hold().unwrap();
        eng.cancel_hold();
        let _ = eng.cleanup_text(
            "ну типа привет кот",
            &DictationContext {
                channel_hint: "devops".into(),
                ..Default::default()
            },
        );
        println!("fsm smoke ok");
    }

    #[cfg(windows)]
    {
        if let Err(e) = win_app::run(application_data_dir()) {
            tracing::error!("windows shell failed: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(windows)]
mod win_app;
