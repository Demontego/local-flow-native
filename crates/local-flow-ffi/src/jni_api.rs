//! JNI surface for Android IME. Same cdylib as the C ABI.
//!
//! jni 0.22: `EnvUnowned` + `with_env` for every exported method.

use crate::c_api::{
    lf_context_free, lf_context_new, lf_engine_cancel_hold, lf_engine_delete_scratch_note,
    lf_engine_end_hold, lf_engine_free, lf_engine_hub_snapshot_json, lf_engine_learn_from_edit,
    lf_engine_load_models, lf_engine_new, lf_engine_partial, lf_engine_personalization_json,
    lf_engine_push_audio, lf_engine_recent_json, lf_engine_save_personalization_json,
    lf_engine_set_destination_scratch, lf_engine_start_hold, lf_engine_undo_learned,
    lf_session_result_free, lf_string_free,
};
use crate::LocalFlowEngine;
use jni::objects::{JClass, JFloatArray, JString};
use jni::sys::{jboolean, jfloatArray, jint, jlong, jstring, JNI_FALSE, JNI_TRUE};
use jni::{Env, EnvUnowned};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

type JniResult<T> = Result<T, jni::errors::Error>;

fn jstr(value: &JString) -> String {
    value.to_string()
}

fn cstr(value: &JString) -> CString {
    CString::new(jstr(value)).unwrap_or_else(|_| CString::new("").unwrap())
}

fn empty_c() -> CString {
    CString::new("").unwrap()
}

fn to_jstring(env: &mut Env, value: &str) -> jstring {
    env.new_string(value)
        .map(|s| s.into_raw())
        .unwrap_or(ptr::null_mut())
}

fn take_c_string(ptr: *mut c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    let owned = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned();
    lf_string_free(ptr);
    owned
}

fn peek_c_string(ptr: *mut c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

fn resolve_string(unowned: &mut EnvUnowned, f: impl FnOnce(&mut Env) -> JniResult<jstring>) -> jstring {
    unowned
        .with_env(f)
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

fn engine_string(
    unowned: &mut EnvUnowned,
    handle: jlong,
    null_fallback: &str,
    call: impl FnOnce(*mut LocalFlowEngine) -> *mut c_char,
) -> jstring {
    let fallback = null_fallback.to_string();
    resolve_string(unowned, move |env| {
        if handle == 0 {
            return Ok(to_jstring(env, &fallback));
        }
        let text = take_c_string(call(handle as *mut LocalFlowEngine));
        Ok(to_jstring(env, &text))
    })
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeCreate(
    mut unowned: EnvUnowned,
    _class: JClass,
    data_dir: JString,
) -> jlong {
    unowned
        .with_env(|_env| -> JniResult<jlong> {
            let Ok(c_dir) = CString::new(jstr(&data_dir)) else {
                return Ok(0);
            };
            Ok(lf_engine_new(c_dir.as_ptr()) as jlong)
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeFree(
    _unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) {
    if handle != 0 {
        lf_engine_free(handle as *mut LocalFlowEngine);
    }
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeLoadModels(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) -> jstring {
    engine_string(&mut unowned, handle, "error: null engine", |eng| {
        lf_engine_load_models(eng)
    })
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeStartHold(
    _unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) -> jint {
    if handle == 0 {
        return -1;
    }
    lf_engine_start_hold(handle as *mut LocalFlowEngine)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeCancelHold(
    _unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) {
    if handle != 0 {
        lf_engine_cancel_hold(handle as *mut LocalFlowEngine);
    }
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativePushAudio(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    samples: jfloatArray,
) -> jint {
    unowned
        .with_env(|env| -> JniResult<jint> {
            if handle == 0 || samples.is_null() {
                return Ok(-1);
            }
            let array = unsafe { JFloatArray::from_raw(env, samples) };
            let len = match array.len(env) {
                Ok(n) => n,
                Err(_) => return Ok(-1),
            };
            let mut buf = vec![0f32; len];
            if len > 0 && array.get_region(env, 0, &mut buf).is_err() {
                return Ok(-1);
            }
            Ok(lf_engine_push_audio(
                handle as *mut LocalFlowEngine,
                buf.as_ptr(),
                buf.len() as i32,
            ))
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativePartial(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) -> jstring {
    engine_string(&mut unowned, handle, "", |eng| lf_engine_partial(eng))
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeEndHold(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    app_name: JString,
    bundle_id: JString,
    before_text: JString,
) -> jstring {
    resolve_string(&mut unowned, |env| {
        if handle == 0 {
            return Ok(to_jstring(env, ""));
        }
        let app = cstr(&app_name);
        let bid = cstr(&bundle_id);
        let before = cstr(&before_text);
        let empty = empty_c();
        let ctx = lf_context_new(
            app.as_ptr(),
            bid.as_ptr(),
            empty.as_ptr(),
            before.as_ptr(),
            empty.as_ptr(),
            empty.as_ptr(),
            empty.as_ptr(),
            empty.as_ptr(),
        );
        let result = lf_engine_end_hold(handle as *mut LocalFlowEngine, ctx);
        lf_context_free(ctx);
        if result.is_null() {
            return Ok(to_jstring(env, ""));
        }
        let clean = peek_c_string(unsafe { (*result).clean });
        lf_session_result_free(result);
        Ok(to_jstring(env, &clean))
    })
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeHubSnapshot(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) -> jstring {
    engine_string(&mut unowned, handle, "{}", |eng| {
        lf_engine_hub_snapshot_json(eng)
    })
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativePersonalization(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) -> jstring {
    engine_string(&mut unowned, handle, "{}", |eng| {
        lf_engine_personalization_json(eng)
    })
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeSavePersonalization(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    json: JString,
) -> jstring {
    resolve_string(&mut unowned, |env| {
        if handle == 0 {
            return Ok(to_jstring(env, "error: null engine"));
        }
        let payload = cstr(&json);
        let result = take_c_string(lf_engine_save_personalization_json(
            handle as *mut LocalFlowEngine,
            payload.as_ptr(),
        ));
        Ok(to_jstring(env, &result))
    })
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeRecent(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    bundle_id: JString,
) -> jstring {
    resolve_string(&mut unowned, |env| {
        if handle == 0 {
            return Ok(to_jstring(env, "[]"));
        }
        let bid = cstr(&bundle_id);
        let json = take_c_string(lf_engine_recent_json(
            handle as *mut LocalFlowEngine,
            bid.as_ptr(),
        ));
        Ok(to_jstring(env, &json))
    })
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeLearnFromEdit(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    pasted: JString,
    edited: JString,
) -> jstring {
    resolve_string(&mut unowned, |env| {
        if handle == 0 {
            return Ok(to_jstring(env, "[]"));
        }
        let pasted_c = cstr(&pasted);
        let edited_c = cstr(&edited);
        let json = take_c_string(lf_engine_learn_from_edit(
            handle as *mut LocalFlowEngine,
            pasted_c.as_ptr(),
            edited_c.as_ptr(),
        ));
        Ok(to_jstring(env, &json))
    })
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeUndoLearned(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    heard: JString,
) -> jboolean {
    unowned
        .with_env(|_env| -> JniResult<jboolean> {
            if handle == 0 {
                return Ok(JNI_FALSE);
            }
            let heard_c = cstr(&heard);
            Ok(
                if lf_engine_undo_learned(handle as *mut LocalFlowEngine, heard_c.as_ptr()) != 0 {
                    JNI_TRUE
                } else {
                    JNI_FALSE
                },
            )
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeDeleteScratchNote(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    id: JString,
) -> jstring {
    resolve_string(&mut unowned, |env| {
        if handle == 0 {
            return Ok(to_jstring(env, "error: null engine"));
        }
        let id_c = cstr(&id);
        let result = take_c_string(lf_engine_delete_scratch_note(
            handle as *mut LocalFlowEngine,
            id_c.as_ptr(),
        ));
        Ok(to_jstring(env, &result))
    })
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeSetDestinationScratch(
    _unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    scratch: jboolean,
) {
    if handle != 0 {
        lf_engine_set_destination_scratch(handle as *mut LocalFlowEngine, i32::from(scratch));
    }
}
