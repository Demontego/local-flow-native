//! Primary: **tap Right Ctrl** toggles listen.
//! Secondary: **hold Ctrl+Alt** (legacy).

use super::UserEvent;
use std::thread;
use std::time::{Duration, Instant};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, VK_CONTROL, VK_MENU, VK_RCONTROL,
};
use winit::event_loop::EventLoopProxy;

const TAP_MAX: Duration = Duration::from_millis(350);

pub fn spawn(proxy: EventLoopProxy<UserEvent>) {
    thread::Builder::new()
        .name("lf-hotkey".into())
        .spawn(move || {
            let mut hold = false;
            let mut rctrl_down = false;
            let mut rctrl_at: Option<Instant> = None;
            loop {
                let ctrl = unsafe { GetAsyncKeyState(VK_CONTROL.0.into()) } < 0;
                let alt = unsafe { GetAsyncKeyState(VK_MENU.0.into()) } < 0;
                let rctrl = unsafe { GetAsyncKeyState(VK_RCONTROL.0.into()) } < 0;

                // Secondary: Ctrl+Alt hold.
                let want_hold = ctrl && alt;
                if want_hold && !hold {
                    hold = true;
                    tracing::info!("hotkey PRESS (Ctrl+Alt)");
                    let _ = proxy.send_event(UserEvent::HotkeyPress);
                } else if !want_hold && hold {
                    hold = false;
                    tracing::info!("hotkey RELEASE");
                    let _ = proxy.send_event(UserEvent::HotkeyRelease);
                }

                // Primary: Right Ctrl tap → toggle (UI owns listen state).
                if rctrl && !rctrl_down {
                    rctrl_down = true;
                    rctrl_at = Some(Instant::now());
                } else if !rctrl && rctrl_down {
                    rctrl_down = false;
                    if let Some(at) = rctrl_at.take() {
                        if at.elapsed() <= TAP_MAX && !alt {
                            tracing::info!("Right Ctrl TAP toggle");
                            let _ = proxy.send_event(UserEvent::HotkeyToggle);
                        }
                    }
                }

                thread::sleep(Duration::from_millis(16));
            }
        })
        .expect("hotkey thread");
}
