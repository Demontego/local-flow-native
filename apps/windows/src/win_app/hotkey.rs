//! Hold Ctrl+Alt via GetAsyncKeyState poll (same idea as macOS flagsState).

use super::UserEvent;
use std::thread;
use std::time::Duration;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_CONTROL, VK_MENU};
use winit::event_loop::EventLoopProxy;

pub fn spawn(proxy: EventLoopProxy<UserEvent>) {
    thread::Builder::new()
        .name("lf-hotkey".into())
        .spawn(move || {
            let mut held = false;
            loop {
                let ctrl = unsafe { GetAsyncKeyState(VK_CONTROL.0.into()) } < 0;
                let alt = unsafe { GetAsyncKeyState(VK_MENU.0.into()) } < 0;
                let want = ctrl && alt;
                if want && !held {
                    held = true;
                    tracing::info!("hotkey PRESS (Ctrl+Alt)");
                    let _ = proxy.send_event(UserEvent::HotkeyPress);
                } else if !want && held {
                    held = false;
                    tracing::info!("hotkey RELEASE");
                    let _ = proxy.send_event(UserEvent::HotkeyRelease);
                }
                thread::sleep(Duration::from_millis(16));
            }
        })
        .expect("hotkey thread");
}
