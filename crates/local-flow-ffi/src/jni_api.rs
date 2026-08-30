//! JNI surface for Android IME. Same cdylib as the C ABI.

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
use jni::sys::{jboolean, jfloatArray, jint, jlong, jstring};
use jni::JNIEnv;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

fn jstring_to_string(env: &mut JNIEnv, value: JString) -> String {
    env.get_string(&value)
        .map(|s| s.into())
        .unwrap_or_default()
}

fn to_jstring(env: &mut JNIEnv, value: &str) -> jstring {
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
    mut env: JNIEnv,
    _class: JClass,
    data_dir: JString,
) -> jlong {
    let dir = jstring_to_string(&mut env, data_dir);
    let Ok(c_dir) = CString::new(dir) else {
        return 0;
    };
    lf_engine_new(c_dir.as_ptr()) as jlong
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeFree(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) {
    if handle != 0 {
        lf_engine_free(handle as *mut LocalFlowEngine);
    }
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeLoadModels(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
) -> jstring {
    if handle == 0 {
        return to_jstring(&mut env, "error: null engine");
    }
    let summary = take_c_string(lf_engine_load_models(handle as *mut LocalFlowEngine));
    to_jstring(&mut env, &summary)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeStartHold(
    _env: JNIEnv,
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
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) {
    if handle != 0 {
        lf_engine_cancel_hold(handle as *mut LocalFlowEngine);
    }
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativePushAudio(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    samples: jfloatArray,
) -> jint {
    if handle == 0 || samples.is_null() {
        return -1;
    }
    let array = unsafe { JFloatArray::from_raw(samples) };
    let len = match env.get_array_length(&array) {
        Ok(n) => n as usize,
        Err(_) => return -1,
    };
    let mut buf = vec![0f32; len];
    if len > 0 && env.get_float_array_region(&array, 0, &mut buf).is_err() {
        return -1;
    }
    lf_engine_push_audio(
        handle as *mut LocalFlowEngine,
        buf.as_ptr(),
        buf.len() as i32,
    )
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativePartial(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
) -> jstring {
    if handle == 0 {
        return to_jstring(&mut env, "");
    }
    let text = take_c_string(lf_engine_partial(handle as *mut LocalFlowEngine));
    to_jstring(&mut env, &text)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeEndHold(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    app_name: JString,
    bundle_id: JString,
    before_text: JString,
) -> jstring {
    if handle == 0 {
        return to_jstring(&mut env, "");
    }
    let app = CString::new(jstring_to_string(&mut env, app_name)).unwrap_or_else(|_| empty_c());
    let bid = CString::new(jstring_to_string(&mut env, bundle_id)).unwrap_or_else(|_| empty_c());
    let before =
        CString::new(jstring_to_string(&mut env, before_text)).unwrap_or_else(|_| empty_c());
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
        return to_jstring(&mut env, "");
    }
    let clean = peek_c_string(unsafe { (*result).clean });
    lf_session_result_free(result);
    to_jstring(&mut env, &clean)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeHubSnapshot(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
) -> jstring {
    if handle == 0 {
        return to_jstring(&mut env, "{}");
    }
    let json = take_c_string(lf_engine_hub_snapshot_json(handle as *mut LocalFlowEngine));
    to_jstring(&mut env, &json)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativePersonalization(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
) -> jstring {
    if handle == 0 {
        return to_jstring(&mut env, "{}");
    }
    let json = take_c_string(lf_engine_personalization_json(handle as *mut LocalFlowEngine));
    to_jstring(&mut env, &json)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeSavePersonalization(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    json: JString,
) -> jstring {
    if handle == 0 {
        return to_jstring(&mut env, "error: null engine");
    }
    let payload = CString::new(jstring_to_string(&mut env, json)).unwrap_or_else(|_| empty_c());
    let result = take_c_string(lf_engine_save_personalization_json(
        handle as *mut LocalFlowEngine,
        payload.as_ptr(),
    ));
    to_jstring(&mut env, &result)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeRecent(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    bundle_id: JString,
) -> jstring {
    if handle == 0 {
        return to_jstring(&mut env, "[]");
    }
    let bid = CString::new(jstring_to_string(&mut env, bundle_id)).unwrap_or_else(|_| empty_c());
    let json = take_c_string(lf_engine_recent_json(
        handle as *mut LocalFlowEngine,
        bid.as_ptr(),
    ));
    to_jstring(&mut env, &json)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeLearnFromEdit(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    pasted: JString,
    edited: JString,
) -> jstring {
    if handle == 0 {
        return to_jstring(&mut env, "[]");
    }
    let pasted_c = CString::new(jstring_to_string(&mut env, pasted)).unwrap_or_else(|_| empty_c());
    let edited_c = CString::new(jstring_to_string(&mut env, edited)).unwrap_or_else(|_| empty_c());
    let json = take_c_string(lf_engine_learn_from_edit(
        handle as *mut LocalFlowEngine,
        pasted_c.as_ptr(),
        edited_c.as_ptr(),
    ));
    to_jstring(&mut env, &json)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeUndoLearned(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    heard: JString,
) -> jboolean {
    if handle == 0 {
        return 0;
    }
    let heard_c = CString::new(jstring_to_string(&mut env, heard)).unwrap_or_else(|_| empty_c());
    if lf_engine_undo_learned(handle as *mut LocalFlowEngine, heard_c.as_ptr()) != 0 {
        1
    } else {
        0
    }
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeDeleteScratchNote(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    id: JString,
) -> jstring {
    if handle == 0 {
        return to_jstring(&mut env, "error: null engine");
    }
    let id_c = CString::new(jstring_to_string(&mut env, id)).unwrap_or_else(|_| empty_c());
    let result = take_c_string(lf_engine_delete_scratch_note(
        handle as *mut LocalFlowEngine,
        id_c.as_ptr(),
    ));
    to_jstring(&mut env, &result)
}

#[no_mangle]
pub extern "system" fn Java_ai_localflow_local_1flow_1app_NativeEngine_nativeSetDestinationScratch(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
    scratch: jboolean,
) {
    if handle != 0 {
        lf_engine_set_destination_scratch(handle as *mut LocalFlowEngine, i32::from(scratch != 0));
    }
}
