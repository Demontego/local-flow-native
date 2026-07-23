//! Compact top-right translucent HUD (macOS Overlay.swift parity).

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use winit::dpi::{LogicalPosition, LogicalSize, PhysicalPosition};
use winit::event_loop::ActiveEventLoop;
use winit::platform::windows::WindowAttributesExtWindows;
use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
use winit::window::{Window, WindowAttributes, WindowId, WindowLevel};
use windows::Win32::Foundation::{COLORREF, HWND, RECT};
use windows::Win32::Graphics::Gdi::{
    CreateSolidBrush, DeleteObject, DrawTextW, FillRect, GetDC, ReleaseDC, SetBkMode, SetTextColor,
    DT_LEFT, DT_NOPREFIX, DT_WORDBREAK, HDC, TRANSPARENT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetClientRect, GetWindowLongW, SetLayeredWindowAttributes, SetWindowLongW, SetWindowPos,
    GWL_EXSTYLE, LWA_ALPHA, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW,
    WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
};

const HUD_W: f64 = 280.0;
const HUD_H: f64 = 48.0;
const MARGIN: f64 = 16.0;

pub struct Overlay {
    window: Window,
    text: String,
    visible: bool,
}

impl Overlay {
    pub fn create(event_loop: &ActiveEventLoop) -> Result<Self, Box<dyn std::error::Error>> {
        let attrs = WindowAttributes::default()
            .with_title("Local Flow")
            .with_decorations(false)
            .with_transparent(true)
            .with_resizable(false)
            .with_visible(false)
            .with_skip_taskbar(true)
            .with_window_level(WindowLevel::AlwaysOnTop)
            .with_inner_size(LogicalSize::new(HUD_W, HUD_H));
        let window = event_loop.create_window(attrs)?;
        apply_ex_style(&window)?;
        reposition(&window);
        Ok(Self {
            window,
            text: "Local Flow".into(),
            visible: false,
        })
    }

    pub fn window_id(&self) -> WindowId {
        self.window.id()
    }

    pub fn show(&mut self, text: impl Into<String>) {
        self.text = text.into();
        reposition(&self.window);
        apply_ex_style(&self.window).ok();
        self.window
            .set_outer_position(bottom_center_position(&self.window));
        self.window.set_visible(true);
        // Keep focus on the foreground app (dictation target).
        let _ = unsafe {
            SetWindowPos(
                hwnd_of(&self.window),
                None,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW,
            )
        };
        self.visible = true;
        self.window.request_redraw();
    }

    pub fn hide(&mut self) {
        self.window.set_visible(false);
        self.visible = false;
    }

    pub fn paint(&self) {
        if !self.visible {
            return;
        }
        let hwnd = hwnd_of(&self.window);
        unsafe {
            let mut rect = RECT::default();
            let _ = GetClientRect(hwnd, &mut rect);
            let hdc = GetDC(Some(hwnd));
            if hdc.is_invalid() {
                return;
            }
            paint_hud(hdc, rect, &self.text);
            let _ = ReleaseDC(Some(hwnd), hdc);
        }
    }
}

fn hwnd_of(window: &Window) -> HWND {
    match window.window_handle().expect("handle").as_raw() {
        RawWindowHandle::Win32(h) => HWND(h.hwnd.get() as *mut _),
        _ => unreachable!("win32 only"),
    }
}

fn apply_ex_style(window: &Window) -> Result<(), Box<dyn std::error::Error>> {
    let hwnd = hwnd_of(window);
    unsafe {
        let mut style = GetWindowLongW(hwnd, GWL_EXSTYLE);
        style |= (WS_EX_LAYERED.0 | WS_EX_TOOLWINDOW.0 | WS_EX_TOPMOST.0 | WS_EX_NOACTIVATE.0) as i32;
        SetWindowLongW(hwnd, GWL_EXSTYLE, style);
        // ~58% opacity like macOS calibratedWhite 0.08 alpha 0.58 panel feel
        SetLayeredWindowAttributes(hwnd, COLORREF(0), 210, LWA_ALPHA)?;
    }
    Ok(())
}

fn bottom_center_position(window: &Window) -> PhysicalPosition<i32> {
    let scale = window.scale_factor();
    if let Some(monitor) = window.current_monitor().or_else(|| window.primary_monitor()) {
        let size = monitor.size();
        let pos = monitor.position();
        let w = (HUD_W * scale) as i32;
        let h = (HUD_H * scale) as i32;
        let m = (MARGIN * scale) as i32;
        return PhysicalPosition::new(
            pos.x + (size.width as i32 - w) / 2,
            pos.y + size.height as i32 - h - m - (40.0 * scale) as i32,
        );
    }
    LogicalPosition::new(MARGIN, MARGIN).to_physical(scale)
}

fn reposition(window: &Window) {
    window.set_outer_position(bottom_center_position(window));
}

unsafe fn paint_hud(hdc: HDC, mut rect: RECT, text: &str) {
    // Dark fill (alpha applied to whole layered window).
    let brush = CreateSolidBrush(COLORREF(0x00141414));
    FillRect(hdc, &rect, brush);
    let _ = DeleteObject(brush.into());

    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, COLORREF(0x00EBEBEB));

    let mut wide: Vec<u16> = OsStr::new(text).encode_wide().collect();
    let len = wide.len();
    wide.push(0);

    rect.left += 14;
    rect.top += 14;
    rect.right -= 14;
    rect.bottom -= 14;

    DrawTextW(
        hdc,
        &mut wide[..len],
        &mut rect,
        DT_LEFT | DT_WORDBREAK | DT_NOPREFIX,
    );
}
