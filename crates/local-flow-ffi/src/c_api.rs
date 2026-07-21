//! Stable C ABI for Swift / other shells (alongside UniFFI).

use crate::{FfiContext, LocalFlowEngine};
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_float, c_int};
use std::ptr;
use std::sync::Arc;

#[repr(C)]
pub struct LFContext {
    pub app_name: *const c_char,
    pub bundle_id: *const c_char,
    pub channel_hint: *const c_char,
    pub before_text: *const c_char,
    pub selected_text: *const c_char,
    pub chat_lines: *const c_char,
    pub recent: *const c_char,
    pub screenshot_path: *const c_char,
}

#[repr(C)]
pub struct LFSessionResult {
    pub raw: *mut c_char,
    pub clean: *mut c_char,
    pub press_enter: c_int,
}

fn cstr_to_string(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn to_cstring(s: &str) -> *mut c_char {
    CString::new(s)
        .map(|c| c.into_raw())
        .unwrap_or(ptr::null_mut())
}

fn context_from_c(c: *const LFContext) -> FfiContext {
    if c.is_null() {
        return FfiContext {
            app_name: String::new(),
            bundle_id: String::new(),
            channel_hint: String::new(),
            before_text: String::new(),
            selected_text: String::new(),
            chat_lines: vec![],
            recent: vec![],
            screenshot_path: None,
            ..Default::default()
        };
    }
    let c = unsafe { &*c };
    let chat = cstr_to_string(c.chat_lines);
    let recent = cstr_to_string(c.recent);
    let shot = cstr_to_string(c.screenshot_path);
    FfiContext {
        app_name: cstr_to_string(c.app_name),
        bundle_id: cstr_to_string(c.bundle_id),
        channel_hint: cstr_to_string(c.channel_hint),
        before_text: cstr_to_string(c.before_text),
        selected_text: cstr_to_string(c.selected_text),
        chat_lines: if chat.is_empty() {
            vec![]
        } else {
            chat.lines().map(|s| s.to_string()).collect()
        },
        recent: if recent.is_empty() {
            vec![]
        } else {
            recent.lines().map(|s| s.to_string()).collect()
        },
        screenshot_path: if shot.is_empty() { None } else { Some(shot) },
        ..Default::default()
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_new(data_dir: *const c_char) -> *mut LocalFlowEngine {
    LocalFlowEngine::new(cstr_to_string(data_dir))
        .map(Arc::into_raw)
        .map(|ptr| ptr as *mut LocalFlowEngine)
        .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn lf_engine_free(ptr: *mut LocalFlowEngine) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(Arc::from_raw(ptr));
    }
}

fn eng<'a>(ptr: *mut LocalFlowEngine) -> Option<&'a LocalFlowEngine> {
    if ptr.is_null() {
        None
    } else {
        Some(unsafe { &*ptr })
    }
}

#[no_mangle]
pub extern "C" fn lf_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(s));
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_load_models(ptr: *mut LocalFlowEngine) -> *mut c_char {
    let Some(e) = eng(ptr) else {
        return to_cstring("null engine");
    };
    match e.load_models() {
        Ok(s) => to_cstring(&s),
        Err(err) => to_cstring(&format!("error: {err}")),
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_personalization_json(ptr: *mut LocalFlowEngine) -> *mut c_char {
    let Some(e) = eng(ptr) else {
        return to_cstring("{}");
    };
    match e.personalization_json() {
        Ok(json) => to_cstring(&json),
        Err(err) => to_cstring(&format!("error: {err}")),
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_save_personalization_json(
    ptr: *mut LocalFlowEngine,
    json: *const c_char,
) -> *mut c_char {
    let Some(e) = eng(ptr) else {
        return to_cstring("error: null engine");
    };
    match e.save_personalization_json(cstr_to_string(json)) {
        Ok(()) => to_cstring("ok"),
        Err(err) => to_cstring(&format!("error: {err}")),
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_recent_json(
    ptr: *mut LocalFlowEngine,
    bundle_id: *const c_char,
) -> *mut c_char {
    let Some(e) = eng(ptr) else {
        return to_cstring("[]");
    };
    match e.recent_json(cstr_to_string(bundle_id)) {
        Ok(json) => to_cstring(&json),
        Err(err) => to_cstring(&format!("error: {err}")),
    }
}

pub type LfProgressCb = Option<extern "C" fn(u32, *mut std::ffi::c_void)>;

#[no_mangle]
pub extern "C" fn lf_engine_download_whisper(
    ptr: *mut LocalFlowEngine,
    cb: LfProgressCb,
    userdata: *mut std::ffi::c_void,
) -> *mut c_char {
    let Some(e) = eng(ptr) else {
        return to_cstring("null engine");
    };
    // userdata must remain valid for the duration of this call (Swift keeps it alive).
    let ud = userdata as usize;
    match e.download_whisper_with_progress(|pct| {
        if let Some(cb) = cb {
            cb(pct, ud as *mut std::ffi::c_void);
        }
    }) {
        Ok(s) => to_cstring(&s),
        Err(err) => to_cstring(&format!("error: {err}")),
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_download_qwen(
    ptr: *mut LocalFlowEngine,
    cb: LfProgressCb,
    userdata: *mut std::ffi::c_void,
) -> *mut c_char {
    let Some(e) = eng(ptr) else {
        return to_cstring("null engine");
    };
    let ud = userdata as usize;
    match e.download_qwen_with_progress(|pct| {
        if let Some(cb) = cb {
            cb(pct, ud as *mut std::ffi::c_void);
        }
    }) {
        Ok(s) => to_cstring(&s),
        Err(err) => to_cstring(&format!("error: {err}")),
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_start_hold(ptr: *mut LocalFlowEngine) -> c_int {
    match eng(ptr).and_then(|e| e.start_hold().ok()) {
        Some(()) => 0,
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_cancel_hold(ptr: *mut LocalFlowEngine) {
    if let Some(e) = eng(ptr) {
        e.cancel_hold();
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_push_audio(
    ptr: *mut LocalFlowEngine,
    samples: *const c_float,
    len: c_int,
) -> c_int {
    let Some(e) = eng(ptr) else {
        return -1;
    };
    if samples.is_null() || len <= 0 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(samples, len as usize) };
    match e.push_audio(slice.to_vec()) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_partial(ptr: *mut LocalFlowEngine) -> *mut c_char {
    let Some(e) = eng(ptr) else {
        return to_cstring("");
    };
    match e.partial_transcript() {
        Ok(s) => to_cstring(&s),
        Err(_) => to_cstring(""),
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_end_hold(
    ptr: *mut LocalFlowEngine,
    ctx: *const LFContext,
) -> *mut LFSessionResult {
    let Some(e) = eng(ptr) else {
        return ptr::null_mut();
    };
    match e.end_hold(context_from_c(ctx)) {
        Ok(r) => Box::into_raw(Box::new(LFSessionResult {
            raw: to_cstring(&r.raw),
            clean: to_cstring(&r.clean),
            press_enter: i32::from(r.press_enter),
        })),
        Err(err) => Box::into_raw(Box::new(LFSessionResult {
            raw: to_cstring(&format!("error: {err}")),
            clean: to_cstring(""),
            press_enter: 0,
        })),
    }
}

#[no_mangle]
pub extern "C" fn lf_engine_cleanup_text(
    ptr: *mut LocalFlowEngine,
    raw: *const c_char,
    ctx: *const LFContext,
) -> *mut c_char {
    let Some(e) = eng(ptr) else {
        return to_cstring("error: null engine");
    };
    let raw = cstr_to_string(raw);
    if raw.trim().is_empty() {
        return to_cstring("error: select text first");
    }
    match e.cleanup_text(raw, context_from_c(ctx)) {
        Ok(text) => to_cstring(&text),
        Err(err) => to_cstring(&format!("error: {err}")),
    }
}

#[no_mangle]
pub extern "C" fn lf_session_result_free(r: *mut LFSessionResult) {
    if r.is_null() {
        return;
    }
    unsafe {
        let boxed = Box::from_raw(r);
        lf_string_free(boxed.raw);
        lf_string_free(boxed.clean);
    }
}

#[no_mangle]
pub extern "C" fn lf_context_new(
    app_name: *const c_char,
    bundle_id: *const c_char,
    channel_hint: *const c_char,
    before_text: *const c_char,
    selected_text: *const c_char,
    chat_lines: *const c_char,
    recent: *const c_char,
    screenshot_path: *const c_char,
) -> *mut LFContext {
    // Store owned CStrings in a heap struct for the duration of the call.
    // Callers free via lf_context_free.
    #[repr(C)]
    struct Owned {
        ctx: LFContext,
        app: CString,
        bid: CString,
        ch: CString,
        before: CString,
        sel: CString,
        chat: CString,
        recent: CString,
        shot: CString,
    }
    let cstring = |s: String| CString::new(s).unwrap_or_else(|_| CString::new("").unwrap());
    let app = cstring(cstr_to_string(app_name));
    let bid = cstring(cstr_to_string(bundle_id));
    let ch = cstring(cstr_to_string(channel_hint));
    let before = cstring(cstr_to_string(before_text));
    let sel = cstring(cstr_to_string(selected_text));
    let chat = cstring(cstr_to_string(chat_lines));
    let recent_s = cstring(cstr_to_string(recent));
    let shot = cstring(cstr_to_string(screenshot_path));
    let owned = Box::new(Owned {
        ctx: LFContext {
            app_name: app.as_ptr(),
            bundle_id: bid.as_ptr(),
            channel_hint: ch.as_ptr(),
            before_text: before.as_ptr(),
            selected_text: sel.as_ptr(),
            chat_lines: chat.as_ptr(),
            recent: recent_s.as_ptr(),
            screenshot_path: shot.as_ptr(),
        },
        app,
        bid,
        ch,
        before,
        sel,
        chat,
        recent: recent_s,
        shot,
    });
    let ptr = Box::into_raw(owned);
    unsafe { &mut (*ptr).ctx as *mut LFContext }
}

#[no_mangle]
pub extern "C" fn lf_context_free(ctx: *mut LFContext) {
    if ctx.is_null() {
        return;
    }
    // Recover Owned from ctx field offset 0
    #[repr(C)]
    struct Owned {
        ctx: LFContext,
        app: CString,
        bid: CString,
        ch: CString,
        before: CString,
        sel: CString,
        chat: CString,
        recent: CString,
        shot: CString,
    }
    unsafe {
        let owned = ctx as *mut Owned;
        drop(Box::from_raw(owned));
    }
}

#[no_mangle]
pub extern "C" fn lf_library_version() -> *mut c_char {
    to_cstring(&crate::library_version())
}
