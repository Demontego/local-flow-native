//! Thin Hub: MessageBox snapshot + clipboard learn helpers.

use local_flow_core::session::Engine;
use std::sync::Arc;
use windows::core::PCWSTR;
use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_OK};

fn wide(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

pub fn show_hub(engine: &Arc<Engine>) {
    let json = engine.hub_snapshot_json().unwrap_or_else(|e| format!("error: {e}"));
    let summary = summarize(&json);
    let title = wide("Local Flow Hub");
    let body = wide(&summary);
    unsafe {
        let _ = MessageBoxW(None, PCWSTR(body.as_ptr()), PCWSTR(title.as_ptr()), MB_OK);
    }
}

fn summarize(json: &str) -> String {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(json) else {
        return json.chars().take(800).collect();
    };
    let stats = &v["stats"];
    let sessions = v["sessions"].as_array().map(|a| a.len()).unwrap_or(0);
    let notes = v["notes"].as_array().map(|a| a.len()).unwrap_or(0);
    let last = v["sessions"]
        .as_array()
        .and_then(|a| a.first())
        .and_then(|s| s["preview"].as_str())
        .unwrap_or("—");
    let mut note_preview = String::new();
    if let Some(arr) = v["notes"].as_array() {
        for n in arr.iter().take(5) {
            if let Some(t) = n["text"].as_str() {
                note_preview.push_str("- ");
                note_preview.push_str(&t.chars().take(80).collect::<String>());
                note_preview.push('\n');
            }
        }
    }
    format!(
        "Words today: {}\nWords week: {}\nStreak: {}d\nSessions today: {}\nLogged sessions: {}\nNotes: {}\nLast: {}\n\nRecent notes:\n{}",
        stats["words_today"],
        stats["words_week"],
        stats["streak_days"],
        stats["sessions_today"],
        sessions,
        notes,
        last,
        if note_preview.is_empty() {
            "(none)".into()
        } else {
            note_preview
        }
    )
}

pub fn learn_from_clipboard(engine: &Arc<Engine>, last_clean: &str) -> String {
    let edited = clipboard_text().unwrap_or_default();
    let edited = edited.trim().to_string();
    if last_clean.is_empty() {
        return "Dictate first, then edit clipboard and Learn".into();
    }
    if edited.is_empty() || edited == last_clean {
        return "Clipboard empty or same as last paste".into();
    }
    match engine.learn_from_edit(last_clean, &edited) {
        Ok(json) => {
            if json == "[]" {
                "No learnable edit".into()
            } else {
                format!("Learned: {json}")
            }
        }
        Err(e) => format!("Learn error: {e}"),
    }
}

fn clipboard_text() -> Option<String> {
    use arboard::Clipboard;
    Clipboard::new().ok()?.get_text().ok()
}
