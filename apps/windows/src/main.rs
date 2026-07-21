//! Windows tray shell — same `local-flow-core` session API as macOS.
//!
//! Full tray/hotkey/cpal wiring is `cfg(windows)`. On other hosts this binary
//! smoke-tests the shared engine so CI on macOS still validates the crate.

use local_flow_core::context::DictationContext;
use local_flow_core::session::Engine;

fn main() {
    tracing_subscriber::fmt::init();
    println!("local-flow-windows {}", Engine::version());

    #[cfg(not(windows))]
    {
        let eng = Engine::with_defaults();
        let summary = eng.load_models().expect("load");
        println!("engine ready ({summary}) — rebuild with --target x86_64-pc-windows-msvc on Windows for tray UI");
        // Smoke session FSM
        eng.start_hold().unwrap();
        eng.cancel_hold();
        let _ = eng.cleanup_text(
            "ну типа привет кот",
            &DictationContext {
                channel_hint: "ds-team".into(),
                ..Default::default()
            },
        );
        println!("fsm smoke ok");
    }

    #[cfg(windows)]
    {
        windows_run();
    }
}

#[cfg(windows)]
fn windows_run() {
    // Placeholder for tray + Ctrl+Alt hold + WASAPI/cpal capture + UI Automation context.
    // Same Engine API as macOS Swift shell.
    let eng = Engine::with_defaults();
    let summary = eng.load_models().expect("load models");
    println!("Local Flow Windows ready ({summary})");
    println!("TODO: tray-icon + global-hotkey + cpal loop (scaffold in place)");
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
