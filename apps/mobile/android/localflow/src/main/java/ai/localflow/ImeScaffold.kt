package ai.localflow

/**
 * Scaffold for Android IME — wire UniFFI `LocalFlowEngine` when native lib is packaged.
 *
 * Expected flow:
 *  hold mic → collect PCM float32 @ 16kHz → engine.startHold/pushAudio/endHold → commitText
 */
object ImeScaffold {
    const val SAMPLE_RATE = 16_000

    fun placeholderStatus(): String = "local-flow-mobile-android-scaffold"
}
