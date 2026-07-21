//! Clipboard + Ctrl+V (+ optional Enter). Restores previous clipboard after paste.

use arboard::Clipboard;
use std::thread;
use std::time::Duration;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY, VK_CONTROL, VK_RETURN, VK_V,
};

pub fn paste_text(text: &str, press_enter: bool) -> Result<(), String> {
    let mut clipboard = Clipboard::new().map_err(|e| e.to_string())?;
    let previous = clipboard.get_text().ok();
    clipboard
        .set_text(text)
        .map_err(|e| format!("clipboard set: {e}"))?;

    // Let the target app notice clipboard change.
    thread::sleep(Duration::from_millis(40));
    send_ctrl_v()?;
    thread::sleep(Duration::from_millis(80));

    if press_enter {
        send_key(VK_RETURN, false)?;
        send_key(VK_RETURN, true)?;
    }

    if let Some(prev) = previous {
        // Best-effort restore; ignore errors (user may have copied again).
        let _ = clipboard.set_text(prev);
    }
    Ok(())
}

fn send_ctrl_v() -> Result<(), String> {
    send_key(VK_CONTROL, false)?;
    send_key(VK_V, false)?;
    send_key(VK_V, true)?;
    send_key(VK_CONTROL, true)?;
    Ok(())
}

fn send_key(vk: VIRTUAL_KEY, up: bool) -> Result<(), String> {
    let flags = if up {
        KEYEVENTF_KEYUP
    } else {
        KEYBD_EVENT_FLAGS(0)
    };
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let sent = unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
    if sent != 1 {
        return Err("SendInput failed".into());
    }
    Ok(())
}
