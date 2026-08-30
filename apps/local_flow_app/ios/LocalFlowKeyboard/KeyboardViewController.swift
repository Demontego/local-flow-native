import AVFoundation
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let appGroup = "group.ai.localflow.app"
    private let statusLabel = UILabel()
    private let dictateButton = UIButton(type: .system)
    private var engine: KeyboardEngine?
    private var audioEngine: AVAudioEngine?
    private var isHolding = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        dictateButton.setTitle("Hold to talk", for: .normal)
        dictateButton.addTarget(self, action: #selector(touchDown), for: .touchDown)
        dictateButton.addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(dictateButton)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        bootstrapEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatus()
    }

    private func bootstrapEngine() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            statusLabel.text = "App Group unavailable"
            return
        }
        let dataDir = container.appendingPathComponent("LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        engine = KeyboardEngine(dataDirectory: dataDir.path)
        if let engine {
            let summary = engine.loadModels()
            statusLabel.text = summary
        } else {
            statusLabel.text = "Native engine missing. Rebuild with make package-ios-libs."
        }
    }

    private var modelsReady: Bool {
        UserDefaults(suiteName: appGroup)?.bool(forKey: "modelsReady") ?? false
    }

    private func refreshStatus() {
        if engine == nil {
            statusLabel.text = "Native engine missing"
        } else if !modelsReady {
            statusLabel.text = "Open Local Flow to download Whisper and Gemma 4."
        } else {
            statusLabel.text = "Ready. Hold to talk."
        }
    }

    @objc private func touchDown() {
        guard let engine else { return }
        guard modelsReady else {
            statusLabel.text = "Download models in the Local Flow app first."
            return
        }
        guard engine.startHold() else {
            statusLabel.text = "Could not start hold"
            return
        }
        isHolding = true
        statusLabel.text = "Listening…"
        startAudio(engine: engine)
    }

    @objc private func touchUp() {
        guard isHolding else { return }
        isHolding = false
        stopAudio()
        statusLabel.text = "Transcribing…"
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = self?.engine?.endHold(beforeText: before) ?? ""
            DispatchQueue.main.async {
                if text.isEmpty {
                    self?.statusLabel.text = "No speech"
                } else {
                    self?.textDocumentProxy.insertText(text)
                    self?.statusLabel.text = "Inserted"
                }
            }
        }
    }

    private func startAudio(engine: KeyboardEngine) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        let targetRate: Double = 16_000
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            if abs(format.sampleRate - targetRate) < 1 {
                let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
                engine.pushAudio(samples)
            } else {
                // ponytail: naive downsample; replace with AVAudioConverter if quality suffers.
                let ratio = format.sampleRate / targetRate
                var out: [Float] = []
                out.reserveCapacity(Int(Double(frameCount) / ratio) + 1)
                var i = 0.0
                while Int(i) < frameCount {
                    out.append(channel[Int(i)])
                    i += ratio
                }
                engine.pushAudio(out)
            }
            let partial = engine.partial()
            if !partial.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.statusLabel.text = partial
                }
            }
        }
        do {
            try audio.start()
            audioEngine = audio
        } catch {
            engine.cancelHold()
            statusLabel.text = "Mic failed: \(error.localizedDescription)"
            isHolding = false
        }
    }

    private func stopAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
