//! Local Hub window: Home / History / Notes / Dictionary + clipboard learn.

use local_flow_core::personalization::Replacement;
use local_flow_core::session::Engine;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::Arc;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{GetStockObject, UpdateWindow, HBRUSH, WHITE_BRUSH};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetClientRect, GetMessageW,
    GetWindowLongPtrW, GetWindowTextLengthW, GetWindowTextW, LoadCursorW, MessageBoxW, MoveWindow,
    PostQuitMessage, RegisterClassW, SetWindowLongPtrW, SetWindowTextW, ShowWindow, TranslateMessage,
    CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, GWLP_USERDATA, HMENU, IDC_ARROW, MB_OK, MSG,
    SW_SHOW, WINDOW_EX_STYLE, WINDOW_STYLE, WM_COMMAND, WM_CREATE, WM_DESTROY, WM_SIZE, WNDCLASSW,
    WS_BORDER, WS_CHILD, WS_CLIPSIBLINGS, WS_OVERLAPPEDWINDOW, WS_TABSTOP, WS_VISIBLE, WS_VSCROLL,
};

// EDIT / BUTTON styles (WinUser.h) — avoid depending on optional feature exports.
const ES_MULTILINE: u32 = 0x0004;
const ES_AUTOVSCROLL: u32 = 0x0040;
const ES_READONLY: u32 = 0x0800;
const BS_PUSHBUTTON: u32 = 0x0000;

const IDC_BODY: isize = 100;
const IDC_STATUS: isize = 101;
const IDC_HOME: isize = 110;
const IDC_HISTORY: isize = 111;
const IDC_NOTES: isize = 112;
const IDC_DICT: isize = 113;
const IDC_REFRESH: isize = 120;
const IDC_ADD_RULE: isize = 121;
const IDC_DEL_NOTE: isize = 122;
const IDC_TOGGLE_CLEANUP: isize = 123;
const IDC_HEARD: isize = 130;
const IDC_REPL: isize = 131;

static HUB_HWND: AtomicIsize = AtomicIsize::new(0);

struct HubState {
    engine: Arc<Engine>,
    tab: i32,
    body: HWND,
    status: HWND,
    heard: HWND,
    repl: HWND,
    sessions: Vec<String>,
    notes: Vec<(String, String)>,
    dict: Vec<(String, String)>,
}

fn wide(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn hwnd_text(hwnd: HWND) -> String {
    unsafe {
        let len = GetWindowTextLengthW(hwnd);
        if len <= 0 {
            return String::new();
        }
        let mut buf = vec![0u16; (len + 1) as usize];
        let n = GetWindowTextW(hwnd, &mut buf);
        String::from_utf16_lossy(&buf[..n as usize])
    }
}

fn set_text(hwnd: HWND, text: &str) {
    let w = wide(text);
    unsafe {
        let _ = SetWindowTextW(hwnd, PCWSTR(w.as_ptr()));
    }
}

fn child(
    parent: HWND,
    class: PCWSTR,
    title: &str,
    style_bits: u32,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    id: isize,
) -> HWND {
    let t = wide(title);
    let style = WINDOW_STYLE(style_bits | WS_CHILD.0 | WS_VISIBLE.0 | WS_CLIPSIBLINGS.0);
    unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class,
            PCWSTR(t.as_ptr()),
            style,
            x,
            y,
            cx,
            cy,
            Some(parent),
            Some(HMENU(id as *mut _)),
            None,
            None,
        )
        .unwrap_or_default()
    }
}

fn load_lists(state: &mut HubState) {
    let json = state
        .engine
        .hub_snapshot_json()
        .unwrap_or_else(|e| format!(r#"{{"error":"{e}"}}"#));
    let v: serde_json::Value = serde_json::from_str(&json).unwrap_or_default();
    let stats = &v["stats"];
    state.sessions = v["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|s| {
            let mode = s["mode"].as_str().unwrap_or("");
            let words = s["word_count"].as_u64().unwrap_or(0);
            let prev = s["preview"].as_str().unwrap_or("");
            format!("[{mode}] {words}w  {prev}")
        })
        .collect();
    state.notes = v["notes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|n| {
            Some((
                n["id"].as_str()?.to_string(),
                n["text"].as_str().unwrap_or("").to_string(),
            ))
        })
        .collect();
    let p = state.engine.personalization();
    state.dict = p
        .dictionary
        .iter()
        .map(|r| (r.heard.clone(), r.replace_with.clone()))
        .collect();
    set_text(
        state.status,
        &format!(
            "Today {} · week {} · streak {}d · sessions {} · cleanup {}",
            stats["words_today"].as_u64().unwrap_or(0),
            stats["words_week"].as_u64().unwrap_or(0),
            stats["streak_days"].as_u64().unwrap_or(0),
            stats["sessions_today"].as_u64().unwrap_or(0),
            if p.cleanup_enabled { "on" } else { "off" }
        ),
    );
    apply_tab(state);
}

fn apply_tab(state: &HubState) {
    let body = match state.tab {
        0 => {
            let last = state
                .sessions
                .first()
                .cloned()
                .unwrap_or_else(|| "—".into());
            format!(
                "Local Flow Hub\r\n\r\n\
Last session: {last}\r\n\
Dictionary rules: {}\r\n\
Scratch notes: {}\r\n\
Sessions logged: {}\r\n\r\n\
Tip: tap Right Ctrl to dictate. Use tray Dictate to Scratch for notes.\r\n\
Add dictionary rules below (Heard → Replace), then Refresh.",
                state.dict.len(),
                state.notes.len(),
                state.sessions.len()
            )
        }
        1 => {
            if state.sessions.is_empty() {
                "No sessions yet.".into()
            } else {
                state.sessions.join("\r\n")
            }
        }
        2 => {
            if state.notes.is_empty() {
                "No scratch notes.".into()
            } else {
                state
                    .notes
                    .iter()
                    .map(|(id, t)| format!("{id}: {t}"))
                    .collect::<Vec<_>>()
                    .join("\r\n")
            }
        }
        _ => {
            if state.dict.is_empty() {
                "No dictionary rules.".into()
            } else {
                state
                    .dict
                    .iter()
                    .map(|(h, r)| format!("{h} → {r}"))
                    .collect::<Vec<_>>()
                    .join("\r\n")
            }
        }
    };
    set_text(state.body, &body);
}

fn add_rule(state: &mut HubState) {
    let heard = hwnd_text(state.heard).trim().to_string();
    let repl = hwnd_text(state.repl).trim().to_string();
    if heard.is_empty() || repl.is_empty() {
        set_text(state.status, "Dictionary rule needs both values");
        return;
    }
    let mut p = state.engine.personalization();
    p.dictionary.push(Replacement {
        heard,
        replace_with: repl,
    });
    match state.engine.save_personalization(&p) {
        Ok(()) => {
            set_text(state.heard, "");
            set_text(state.repl, "");
            set_text(state.status, "Dictionary rule saved");
            load_lists(state);
        }
        Err(e) => set_text(state.status, &format!("Save failed: {e}")),
    }
}

fn delete_first_note(state: &mut HubState) {
    let Some((id, _)) = state.notes.first().cloned() else {
        set_text(state.status, "No notes to delete");
        return;
    };
    match state.engine.delete_scratch_note(&id) {
        Ok(()) => {
            set_text(state.status, "Deleted top note");
            load_lists(state);
        }
        Err(e) => set_text(state.status, &format!("Delete failed: {e}")),
    }
}

fn toggle_cleanup(state: &mut HubState) {
    let mut p = state.engine.personalization();
    p.cleanup_enabled = !p.cleanup_enabled;
    let label = if p.cleanup_enabled { "on" } else { "off" };
    match state.engine.save_personalization(&p) {
        Ok(()) => {
            set_text(state.status, &format!("Cleanup {label}"));
            load_lists(state);
        }
        Err(e) => set_text(state.status, &format!("Save failed: {e}")),
    }
}

unsafe extern "system" fn hub_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_CREATE => {
            let create = &*(lparam.0
                as *const windows::Win32::UI::WindowsAndMessaging::CREATESTRUCTW);
            let engine = Arc::from_raw(create.lpCreateParams as *const Engine);

            let body = child(
                hwnd,
                w!("EDIT"),
                "",
                WS_BORDER.0 | WS_VSCROLL.0 | WS_TABSTOP.0 | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                12,
                48,
                560,
                280,
                IDC_BODY,
            );
            let status = child(
                hwnd,
                w!("STATIC"),
                "",
                0,
                12,
                336,
                560,
                20,
                IDC_STATUS,
            );
            for (label, id, x, cx) in [
                ("Home", IDC_HOME, 12, 72),
                ("History", IDC_HISTORY, 90, 72),
                ("Notes", IDC_NOTES, 168, 72),
                ("Dictionary", IDC_DICT, 246, 88),
                ("Refresh", IDC_REFRESH, 344, 72),
                ("Cleanup", IDC_TOGGLE_CLEANUP, 424, 80),
            ] {
                let _ = child(
                    hwnd,
                    w!("BUTTON"),
                    label,
                    WS_TABSTOP.0 | BS_PUSHBUTTON,
                    x,
                    12,
                    cx,
                    28,
                    id,
                );
            }
            let _ = child(hwnd, w!("STATIC"), "Heard:", 0, 12, 364, 48, 20, 0);
            let heard = child(
                hwnd,
                w!("EDIT"),
                "",
                WS_BORDER.0 | WS_TABSTOP.0,
                64,
                360,
                140,
                24,
                IDC_HEARD,
            );
            let _ = child(hwnd, w!("STATIC"), "->", 0, 210, 364, 16, 20, 0);
            let repl = child(
                hwnd,
                w!("EDIT"),
                "",
                WS_BORDER.0 | WS_TABSTOP.0,
                230,
                360,
                140,
                24,
                IDC_REPL,
            );
            let _ = child(
                hwnd,
                w!("BUTTON"),
                "Add rule",
                WS_TABSTOP.0 | BS_PUSHBUTTON,
                380,
                358,
                80,
                28,
                IDC_ADD_RULE,
            );
            let _ = child(
                hwnd,
                w!("BUTTON"),
                "Del note",
                WS_TABSTOP.0 | BS_PUSHBUTTON,
                468,
                358,
                72,
                28,
                IDC_DEL_NOTE,
            );

            let mut state = Box::new(HubState {
                engine,
                tab: 0,
                body,
                status,
                heard,
                repl,
                sessions: vec![],
                notes: vec![],
                dict: vec![],
            });
            load_lists(&mut state);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, Box::into_raw(state) as isize);
            LRESULT(0)
        }
        WM_SIZE => {
            let mut rect = RECT::default();
            let _ = GetClientRect(hwnd, &mut rect);
            let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut HubState;
            if !state.is_null() {
                let s = &*state;
                let w = (rect.right - rect.left - 24).max(100);
                let h = (rect.bottom - rect.top - 140).max(80);
                let _ = MoveWindow(s.body, 12, 48, w, h, true);
                let _ = MoveWindow(s.status, 12, rect.bottom - 76, w, 20, true);
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            let id = (wparam.0 & 0xFFFF) as isize;
            let state_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut HubState;
            if state_ptr.is_null() {
                return LRESULT(0);
            }
            let state = &mut *state_ptr;
            match id {
                IDC_HOME => {
                    state.tab = 0;
                    apply_tab(state);
                }
                IDC_HISTORY => {
                    state.tab = 1;
                    apply_tab(state);
                }
                IDC_NOTES => {
                    state.tab = 2;
                    apply_tab(state);
                }
                IDC_DICT => {
                    state.tab = 3;
                    apply_tab(state);
                }
                IDC_REFRESH => load_lists(state),
                IDC_ADD_RULE => add_rule(state),
                IDC_DEL_NOTE => delete_first_note(state),
                IDC_TOGGLE_CLEANUP => toggle_cleanup(state),
                _ => {}
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
            if ptr != 0 {
                drop(Box::from_raw(ptr as *mut HubState));
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            }
            HUB_HWND.store(0, Ordering::SeqCst);
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Modal Hub window (blocks tray worker until closed — same as MessageBox before).
pub fn show_hub(engine: &Arc<Engine>) {
    let existing = HUB_HWND.load(Ordering::SeqCst);
    if existing != 0 {
        unsafe {
            let _ = ShowWindow(HWND(existing as *mut _), SW_SHOW);
        }
        return;
    }

    let class_name = w!("LocalFlowHubWnd");
    unsafe {
        let wc = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(hub_wnd_proc),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(GetStockObject(WHITE_BRUSH).0),
            lpszClassName: class_name,
            ..Default::default()
        };
        let _ = RegisterClassW(&wc);

        let eng = Arc::clone(engine);
        let raw = Arc::into_raw(eng);
        let title = wide("Local Flow Hub");
        let hwnd = match CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class_name,
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            600,
            460,
            None,
            None,
            None,
            Some(raw as *const _),
        ) {
            Ok(h) => h,
            Err(_) => {
                drop(Arc::from_raw(raw));
                let _ = MessageBoxW(
                    None,
                    w!("Could not open Hub window"),
                    w!("Local Flow Hub"),
                    MB_OK,
                );
                return;
            }
        };
        HUB_HWND.store(hwnd.0 as isize, Ordering::SeqCst);
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = UpdateWindow(hwnd);

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).into() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
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
    format!(
        "Words today: {}\nWords week: {}\nStreak: {}d\nSessions today: {}\nLogged sessions: {}\nNotes: {}\nLast: {}",
        stats["words_today"],
        stats["words_week"],
        stats["streak_days"],
        stats["sessions_today"],
        sessions,
        notes,
        last,
    )
}

#[cfg(test)]
mod tests {
    use super::summarize;

    #[test]
    fn summarize_reads_stats() {
        let json = r#"{"stats":{"words_today":3,"words_week":3,"streak_days":1,"sessions_today":1},"sessions":[{"preview":"hi"}],"notes":[]}"#;
        let s = summarize(json);
        assert!(s.contains("Words today: 3"));
        assert!(s.contains("Last: hi"));
    }
}
