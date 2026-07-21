//! Tray + Ctrl+Alt hold-to-talk + mic + clipboard paste.

mod audio;
mod hotkey;
mod paste;

use local_flow_core::config::EngineConfig;
use local_flow_core::context::DictationContext;
use local_flow_core::session::{Engine, SessionPhase};
use parking_lot::Mutex;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::thread;
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};
use winit::application::ApplicationHandler;
use winit::event::StartCause;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

enum UserEvent {
    Menu(tray_icon::menu::MenuId),
    HotkeyPress,
    HotkeyRelease,
    Status(String),
}

enum WorkerCmd {
    HoldStart,
    HoldEnd,
    LoadModels,
    DownloadWhisper,
    DownloadQwen,
    Shutdown,
}

pub fn run(data_dir: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    std::fs::create_dir_all(&data_dir)?;
    let engine = Arc::new(Engine::new(EngineConfig::new(&data_dir)));

    let event_loop = EventLoop::<UserEvent>::with_user_event().build()?;
    let proxy = event_loop.create_proxy();

    // Forward muda menu clicks into winit.
    let menu_proxy = proxy.clone();
    MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
        let _ = menu_proxy.send_event(UserEvent::Menu(event.id));
    }));

    let listening = Arc::new(AtomicBool::new(false));
    let (worker_tx, worker_rx) = mpsc::channel::<WorkerCmd>();
    let status_proxy = proxy.clone();
    let eng_worker = Arc::clone(&engine);
    let listening_worker = Arc::clone(&listening);
    thread::Builder::new()
        .name("lf-worker".into())
        .spawn(move || worker_loop(eng_worker, worker_rx, listening_worker, status_proxy))?;

    // Boot: load whatever models are already on disk.
    let _ = worker_tx.send(WorkerCmd::LoadModels);

    let hotkey_proxy = proxy.clone();
    hotkey::spawn(hotkey_proxy);

    let mut app = App {
        proxy,
        worker_tx,
        engine,
        listening,
        tray: None,
        window: None,
        item_load: None,
        item_whisper: None,
        item_qwen: None,
        item_quit: None,
    };
    event_loop.run_app(&mut app)?;
    Ok(())
}

fn worker_loop(
    engine: Arc<Engine>,
    rx: Receiver<WorkerCmd>,
    listening: Arc<AtomicBool>,
    proxy: EventLoopProxy<UserEvent>,
) {
    let capture = Mutex::new(None::<audio::Capture>);
    while let Ok(cmd) = rx.recv() {
        match cmd {
            WorkerCmd::Shutdown => break,
            WorkerCmd::LoadModels => {
                let _ = proxy.send_event(UserEvent::Status("Loading models…".into()));
                match engine.load_models() {
                    Ok(s) => {
                        let _ = proxy.send_event(UserEvent::Status(format!("Ready · {s}")));
                    }
                    Err(e) => {
                        let _ = proxy.send_event(UserEvent::Status(format!("Load failed: {e}")));
                    }
                }
            }
            WorkerCmd::DownloadWhisper => {
                let _ = proxy.send_event(UserEvent::Status("Downloading Whisper…".into()));
                match engine.download_whisper(|p| {
                    if p % 10 == 0 {
                        let _ = proxy.send_event(UserEvent::Status(format!("Whisper {p}%")));
                    }
                }) {
                    Ok(s) => {
                        let _ = proxy.send_event(UserEvent::Status(s));
                        let _ = engine.load_models();
                    }
                    Err(e) => {
                        let _ = proxy.send_event(UserEvent::Status(format!("Whisper dl: {e}")));
                    }
                }
            }
            WorkerCmd::DownloadQwen => {
                let _ = proxy.send_event(UserEvent::Status("Downloading Qwen…".into()));
                match engine.download_qwen(|p| {
                    if p % 5 == 0 {
                        let _ = proxy.send_event(UserEvent::Status(format!("Qwen {p}%")));
                    }
                }) {
                    Ok(s) => {
                        let _ = proxy.send_event(UserEvent::Status(s));
                        let _ = engine.load_models();
                    }
                    Err(e) => {
                        let _ = proxy.send_event(UserEvent::Status(format!("Qwen dl: {e}")));
                    }
                }
            }
            WorkerCmd::HoldStart => {
                if engine.phase() != SessionPhase::Idle {
                    continue;
                }
                if let Err(e) = engine.start_hold() {
                    tracing::warn!("start_hold: {e}");
                    continue;
                }
                listening.store(true, Ordering::SeqCst);
                let eng = Arc::clone(&engine);
                match audio::Capture::start(move |samples| {
                    let _ = eng.push_audio(samples);
                }) {
                    Ok(cap) => {
                        *capture.lock() = Some(cap);
                        let _ = proxy.send_event(UserEvent::Status("Listening…".into()));
                    }
                    Err(e) => {
                        listening.store(false, Ordering::SeqCst);
                        engine.cancel_hold();
                        let _ = proxy.send_event(UserEvent::Status(format!("Mic: {e}")));
                    }
                }
            }
            WorkerCmd::HoldEnd => {
                if !listening.swap(false, Ordering::SeqCst) {
                    continue;
                }
                drop(capture.lock().take());
                let _ = proxy.send_event(UserEvent::Status("Transcribing…".into()));
                let ctx = foreground_context();
                match engine.end_hold(ctx) {
                    Ok(result) => {
                        if result.clean.is_empty() {
                            let _ = proxy.send_event(UserEvent::Status(result.raw));
                        } else {
                            match paste::paste_text(&result.clean, result.press_enter) {
                                Ok(()) => {
                                    let preview: String =
                                        result.clean.chars().take(48).collect();
                                    let _ = proxy.send_event(UserEvent::Status(format!(
                                        "Pasted · {preview}"
                                    )));
                                }
                                Err(e) => {
                                    let _ = proxy
                                        .send_event(UserEvent::Status(format!("Paste: {e}")));
                                }
                            }
                        }
                    }
                    Err(e) => {
                        let _ = proxy.send_event(UserEvent::Status(format!("Dictation: {e}")));
                    }
                }
            }
        }
    }
}

fn foreground_context() -> DictationContext {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        GetForegroundWindow, GetWindowTextLengthW, GetWindowTextW,
    };

    let mut ctx = DictationContext::default();
    unsafe {
        let hwnd: HWND = GetForegroundWindow();
        if hwnd.0.is_null() {
            return ctx;
        }
        let len = GetWindowTextLengthW(hwnd);
        if len > 0 {
            let mut buf = vec![0u16; (len + 1) as usize];
            let n = GetWindowTextW(hwnd, &mut buf);
            if n > 0 {
                buf.truncate(n as usize);
                ctx.app_name = String::from_utf16_lossy(&buf);
            }
        }
        ctx.bundle_id = format!("hwnd:{:?}", hwnd.0);
    }
    ctx
}

struct App {
    proxy: EventLoopProxy<UserEvent>,
    worker_tx: Sender<WorkerCmd>,
    engine: Arc<Engine>,
    listening: Arc<AtomicBool>,
    tray: Option<TrayIcon>,
    /// Hidden window keeps the Win32 message pump alive for the tray.
    window: Option<Window>,
    item_load: Option<MenuItem>,
    item_whisper: Option<MenuItem>,
    item_qwen: Option<MenuItem>,
    item_quit: Option<MenuItem>,
}

impl ApplicationHandler<UserEvent> for App {
    fn new_events(&mut self, event_loop: &ActiveEventLoop, cause: StartCause) {
        if matches!(cause, StartCause::Init) && self.tray.is_none() {
            if let Err(e) = self.build_tray(event_loop) {
                tracing::error!("tray: {e:#}");
                event_loop.exit();
            } else {
                let _ = self.proxy.send_event(UserEvent::Status(
                    "Local Flow · hold Ctrl+Alt to dictate".into(),
                ));
            }
        }
    }

    fn resumed(&mut self, _event_loop: &ActiveEventLoop) {}

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        event_loop.set_control_flow(ControlFlow::Wait);
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        match event {
            UserEvent::Status(msg) => {
                tracing::info!("{msg}");
                if let Some(tray) = &self.tray {
                    let _ = tray.set_tooltip(Some(&msg));
                }
            }
            UserEvent::HotkeyPress => {
                let _ = self.worker_tx.send(WorkerCmd::HoldStart);
            }
            UserEvent::HotkeyRelease => {
                let _ = self.worker_tx.send(WorkerCmd::HoldEnd);
            }
            UserEvent::Menu(id) => {
                if self.item_quit.as_ref().is_some_and(|i| id == i.id()) {
                    let _ = self.worker_tx.send(WorkerCmd::Shutdown);
                    event_loop.exit();
                } else if self.item_load.as_ref().is_some_and(|i| id == i.id()) {
                    let _ = self.worker_tx.send(WorkerCmd::LoadModels);
                } else if self.item_whisper.as_ref().is_some_and(|i| id == i.id()) {
                    let _ = self.worker_tx.send(WorkerCmd::DownloadWhisper);
                } else if self.item_qwen.as_ref().is_some_and(|i| id == i.id()) {
                    let _ = self.worker_tx.send(WorkerCmd::DownloadQwen);
                }
            }
        }
    }

    fn window_event(
        &mut self,
        _event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        _event: winit::event::WindowEvent,
    ) {
    }
}

impl App {
    fn build_tray(
        &mut self,
        event_loop: &ActiveEventLoop,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let attrs = Window::default_attributes()
            .with_visible(false)
            .with_title("Local Flow");
        self.window = Some(event_loop.create_window(attrs)?);

        let item_load = MenuItem::new("Load models", true, None);
        let item_whisper = MenuItem::new("Download Whisper", true, None);
        let item_qwen = MenuItem::new("Download Qwen3 (~1GB)", true, None);
        let item_quit = MenuItem::new("Quit", true, None);

        let menu = Menu::new();
        menu.append(&item_load)?;
        menu.append(&item_whisper)?;
        menu.append(&item_qwen)?;
        menu.append(&PredefinedMenuItem::separator())?;
        menu.append(&item_quit)?;

        let tray = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_tooltip("Local Flow — hold Ctrl+Alt")
            .with_icon(make_icon())
            .build()?;

        self.item_load = Some(item_load);
        self.item_whisper = Some(item_whisper);
        self.item_qwen = Some(item_qwen);
        self.item_quit = Some(item_quit);
        self.tray = Some(tray);
        let _ = &self.engine;
        let _ = &self.listening;
        Ok(())
    }
}

fn make_icon() -> Icon {
    let bytes = include_bytes!("../../assets/tray-icon.png");
    let img = image::load_from_memory(bytes)
        .expect("tray-icon.png")
        .into_rgba8();
    let (w, h) = img.dimensions();
    Icon::from_rgba(img.into_raw(), w, h).expect("rgba icon")
}
