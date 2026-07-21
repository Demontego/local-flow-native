package ai.localflow.local_flow_app

import android.Manifest
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Hold-to-talk IME: AudioRecord → Rust engine → one final commitText.
 *
 * ponytail: Qwen+Whisper in the IME process is heavy; if OOM on low-RAM devices,
 * move inference to a bound host service.
 */
class LocalFlowImeService : InputMethodService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var engineHandle: Long = 0
    private var statusView: TextView? = null
    private val recording = AtomicBoolean(false)
    private var recordThread: Thread? = null

    override fun onCreate() {
        super.onCreate()
        val dataDir = filesDir.absolutePath
        engineHandle = NativeEngine.nativeCreate(dataDir)
        if (engineHandle != 0L) {
            val summary = NativeEngine.nativeLoadModels(engineHandle)
            setStatus(summary)
        } else {
            setStatus("Engine failed to start")
        }
    }

    override fun onDestroy() {
        recording.set(false)
        recordThread = null
        if (engineHandle != 0L) {
            NativeEngine.nativeFree(engineHandle)
            engineHandle = 0
        }
        super.onDestroy()
    }

    override fun onCreateInputView(): View {
        val root =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(32, 24, 32, 24)
                gravity = Gravity.CENTER_HORIZONTAL
            }
        statusView =
            TextView(this).apply {
                text = "Local Flow"
                textSize = 14f
            }
        val dictate =
            Button(this).apply {
                text = "Hold to talk"
                setOnTouchListener { _, event ->
                    when (event.action) {
                        MotionEvent.ACTION_DOWN -> {
                            startDictation()
                            true
                        }
                        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                            endDictation()
                            true
                        }
                        else -> false
                    }
                }
            }
        root.addView(statusView)
        root.addView(dictate)
        return root
    }

    private fun startDictation() {
        if (engineHandle == 0L || recording.get()) {
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            setStatus("Grant microphone permission in the Local Flow app")
            return
        }
        if (NativeEngine.nativeStartHold(engineHandle) != 0) {
            setStatus("Could not start hold")
            return
        }
        recording.set(true)
        setStatus("Listening…")
        recordThread =
            thread(name = "local-flow-record", isDaemon = true) {
                captureLoop()
            }
    }

    private fun endDictation() {
        if (!recording.getAndSet(false)) {
            return
        }
        setStatus("Transcribing…")
        thread(name = "local-flow-end", isDaemon = true) {
            // Let the recorder exit before end_hold.
            recordThread?.join(500)
            recordThread = null
            val text =
                NativeEngine.nativeEndHold(
                    engineHandle,
                    "Android",
                    packageName,
                    currentInputConnection
                        ?.getTextBeforeCursor(80, 0)
                        ?.toString()
                        .orEmpty(),
                )
            mainHandler.post {
                if (text.isNotBlank()) {
                    currentInputConnection?.commitText(text, 1)
                    setStatus("Inserted")
                } else {
                    setStatus("No speech")
                }
            }
        }
    }

    private fun captureLoop() {
        val sampleRate = 16_000
        val minBuf =
            AudioRecord.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
        if (minBuf <= 0) {
            NativeEngine.nativeCancelHold(engineHandle)
            setStatus("AudioRecord unavailable")
            recording.set(false)
            return
        }
        val recorder =
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuf * 2,
            )
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            NativeEngine.nativeCancelHold(engineHandle)
            setStatus("Microphone init failed")
            recording.set(false)
            return
        }
        val shortBuf = ShortArray(minBuf)
        recorder.startRecording()
        var lastPartialMs = 0L
        try {
            while (recording.get()) {
                val n = recorder.read(shortBuf, 0, shortBuf.size)
                if (n > 0 && engineHandle != 0L) {
                    val floats = FloatArray(n) { i -> shortBuf[i] / 32768f }
                    NativeEngine.nativePushAudio(engineHandle, floats)
                    val now = System.currentTimeMillis()
                    if (now - lastPartialMs > 700) {
                        lastPartialMs = now
                        val partial = NativeEngine.nativePartial(engineHandle)
                        if (partial.isNotBlank()) {
                            setStatus(partial)
                        }
                    }
                }
            }
        } finally {
            try {
                recorder.stop()
            } catch (_: IllegalStateException) {
            }
            recorder.release()
        }
    }

    private fun setStatus(text: String) {
        mainHandler.post { statusView?.text = text }
    }
}
