//! JNI surface for Android IME. Same cdylib as the C ABI.
//!
//! Uses jni 0.22 `EnvUnowned` + `with_env` (JNIEnv is no longer the real Env).

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

fn jstring_to_string(value: &JString) -> String {
    value.to_string()
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

fn empty_c() -> CString {
    CString::new("").unwrap()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeCreate(
    mut unowned: EnvUnowned,
    _class: JClass,
    data_dir: JString,
) -> jlong {
    let outcome = unowned.with_env(|_env| -> Result<jlong, jni::errors::Error> {
        let dir = jstring_to_string(&data_dir);
        let Ok(c_dir) = CString::new(dir) else {
            return Ok(0);
        };
        Ok(lf_engine_new(c_dir.as_ptr()) as jlong)
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
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
    let outcome = unowned.with_env(|env| -> Result<jstring, jni::errors::Error> {
        if handle == 0 {
            return Ok(to_jstring(env, "error: null engine"));
        }
        let summary = take_c_string(lf_engine_load_models(handle as *mut LocalFlowEngine));
        Ok(to_jstring(env, &summary))
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
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
    let outcome = unowned.with_env(|env| -> Result<jint, jni::errors::Error> {
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
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativePartial(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, jni::errors::Error> {
        if handle == 0 {
            return Ok(to_jstring(env, ""));
        }
        let text = take_c_string(lf_engine_partial(handle as *mut LocalFlowEngine));
        Ok(to_jstring(env, &text))
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
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
    let outcome = unowned.with_env(|env| -> Result<jstring, jni::errors::Error> {
        if handle == 0 {
            return Ok(to_jstring(env, ""));
        }
        let app = CString::new(jstring_to_string(&app_name)).unwrap_or_else(|_| empty_c());
        let bid = CString::new(jstring_to_string(&bundle_id)).unwrap_or_else(|_| empty_c());
        let before =
            CString::new(jstring_to_string(&before_text)).unwrap_or_else(|_| empty_c());
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
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeHubSnapshot(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, jni::errors::Error> {
        if handle == 0 {
            return Ok(to_jstring(env, "{}"));
        }
        let json = take_c_string(lf_engine_hub_snapshot_json(handle as *mut LocalFlowEngine));
        Ok(to_jstring(env, &json))
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativePersonalization(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, jni::errors::Error> {
        if handle == 0 {
            return Ok(to_jstring(env, "{}"));
        }
        let json = take_c_string(lf_engine_personalization_json(handle as *mut LocalFlowEngine));
        Ok(to_jstring(env, &json))
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeSavePersonalization(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    json: JString,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, jni::errors::Error> {
        if handle == 0 {
            return Ok(to_jstring(env, "error: null engine"));
        }
        let payload = CString::new(jstring_to_string(&json)).unwrap_or_else(|_| empty_c());
        let result = take_c_string(lf_engine_save_personalization_json(
            handle as *mut LocalFlowEngine,
            payload.as_ptr(),
        ));
        Ok(to_jstring(env, &result))
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeRecent(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    bundle_id: JString,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, jni::errors::Error> {
        if handle == 0 {
            return Ok(to_jstring(env, "[]"));
        }
        let bid = CString::new(jstring_to_string(&bundle_id)).unwrap_or_else(|_| empty_c());
        let json = take_c_string(lf_engine_recent_json(
            handle as *mut LocalFlowEngine,
            bid.as_ptr(),
        ));
        Ok(to_jstring(env, &json))
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeLearnFromEdit(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    pasted: JString,
    edited: JString,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, jni::errors::Error> {
        if handle == 0 {
            return Ok(to_jstring(env, "[]"));
        }
        let pasted_c =
            CString::new(jstring_to_string(&pasted)).unwrap_or_else(|_| empty_c());
        let edited_c =
            CString::new(jstring_to_string(&edited)).unwrap_or_else(|_| empty_c());
        let json = take_c_string(lf_engine_learn_from_edit(
            handle as *mut LocalFlowEngine,
            pasted_c.as_ptr(),
            edited_c.as_ptr(),
        ));
        Ok(to_jstring(env, &json))
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeUndoLearned(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    heard: JString,
) -> jboolean {
    let outcome = unowned.with_env(|_env| -> Result<jboolean, jni::errors::Error> {
        if handle == 0 {
            return Ok(JNI_FALSE);
        }
        let heard_c = CString::new(jstring_to_string(&heard)).unwrap_or_else(|_| empty_c());
        Ok(
            if lf_engine_undo_learned(handle as *mut LocalFlowEngine, heard_c.as_ptr()) != 0 {
                JNI_TRUE
            } else {
                JNI_FALSE
            },
        )
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeDeleteScratchNote(
    mut unowned: EnvUnowned,
    _class: JClass,
    handle: jlong,
    id: JString,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, jni::errors::Error> {
        if handle == 0 {
            return Ok(to_jstring(env, "error: null engine"));
        }
        let id_c = CString::new(jstring_to_string(&id)).unwrap_or_else(|_| empty_c());
        let result = take_c_string(lf_engine_delete_scratch_note(
            handle as *mut LocalFlowEngine,
            id_c.as_ptr(),
        ));
        Ok(to_jstring(env, &result))
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
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
