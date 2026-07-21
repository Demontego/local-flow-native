package ai.localflow.local_flow_app

/**
 * JNI bridge into `liblocal_flow_ffi.so` (Rust C ABI + JNI exports).
 */
object NativeEngine {
    init {
        System.loadLibrary("local_flow_ffi")
    }

    external fun nativeCreate(dataDir: String): Long

    external fun nativeFree(handle: Long)

    external fun nativeLoadModels(handle: Long): String

    external fun nativeStartHold(handle: Long): Int

    external fun nativeCancelHold(handle: Long)

    external fun nativePushAudio(handle: Long, samples: FloatArray): Int

    external fun nativePartial(handle: Long): String

    external fun nativeEndHold(
        handle: Long,
        appName: String,
        bundleId: String,
        beforeText: String,
    ): String
}
