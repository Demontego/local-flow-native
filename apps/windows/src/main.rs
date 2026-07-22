//! Windows tray shell — same `local-flow-core` session API as macOS.
//!
//! Hold Ctrl+Alt → speak → release → cleaned text pasted (clipboard + Ctrl+V).
//! Non-Windows hosts smoke-test the engine so macOS CI still validates the crate.

#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(not(windows))]
use local_flow_core::config::EngineConfig;
#[cfg(not(windows))]
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

fn init_logging(data_dir: &std::path::Path) {
    #[cfg(windows)]
    {
        let log_path = data_dir.join("local-flow.log");
        match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
        {
            Ok(f) => {
                tracing_subscriber::fmt()
                    .with_writer(std::sync::Mutex::new(f))
                    .with_ansi(false)
                    .init();
            }
            Err(_) => {
                tracing_subscriber::fmt().with_ansi(false).init();
            }
        }
    }
    #[cfg(not(windows))]
    {
        let _ = data_dir;
        tracing_subscriber::fmt::init();
    }
}

fn main() {
    let data_dir = application_data_dir();
    let _ = std::fs::create_dir_all(&data_dir);
    init_logging(&data_dir);
    tracing::info!("local-flow-windows {}", Engine::version());

    #[cfg(not(windows))]
    {
        let eng = Engine::new(EngineConfig::new(data_dir));
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
        if let Err(e) = win_app::run(data_dir) {
            tracing::error!("windows shell failed: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(windows)]
mod win_app;
