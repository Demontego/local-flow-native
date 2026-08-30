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

    external fun nativeHubSnapshot(handle: Long): String

    external fun nativePersonalization(handle: Long): String

    external fun nativeSavePersonalization(handle: Long, json: String): String

    external fun nativeRecent(handle: Long, bundleId: String): String

    external fun nativeLearnFromEdit(handle: Long, pasted: String, edited: String): String

    external fun nativeUndoLearned(handle: Long, heard: String): Boolean

    external fun nativeDeleteScratchNote(handle: Long, id: String): String

    external fun nativeSetDestinationScratch(handle: Long, scratch: Boolean)
}
