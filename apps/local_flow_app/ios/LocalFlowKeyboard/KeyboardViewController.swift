import AVFoundation
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let appGroup = "group.ai.localflow.app"
    private let statusLabel = UILabel()
    private let dictateButton = UIButton(type: .system)
    private let hintLabel = UILabel()
    private let nextKeyboardButton = UIButton(type: .system)
    private var engine: KeyboardEngine?
    private var audioEngine: AVAudioEngine?
    private var isHolding = false
    private let holdFeedback = UIImpactFeedbackGenerator(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bootstrapEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatus()
    }

    // MARK: - UI

    private func buildUI() {
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel

        dictateButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        dictateButton.setTitleColor(.white, for: .normal)
        dictateButton.setTitleColor(.white, for: .disabled)
        dictateButton.layer.cornerRadius = 12
        dictateButton.layer.masksToBounds = true
        dictateButton.accessibilityLabel = "Dictate"
        dictateButton.accessibilityHint = "Hold to record, release to insert cleaned text."
        dictateButton.addTarget(self, action: #selector(touchDown), for: .touchDown)
        dictateButton.addTarget(
            self,
            action: #selector(touchUp),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )

        hintLabel.font = .preferredFont(forTextStyle: .caption2)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.text = "Hold, speak, release."

        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.accessibilityLabel = "Switch keyboard"
        nextKeyboardButton.addTarget(
            self,
            action: #selector(switchKeyboard),
            for: .touchUpInside
        )
        // Apple requires a way to leave the keyboard unless the globe key is shown.
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey

        let bottomRow = UIStackView(arrangedSubviews: [nextKeyboardButton, hintLabel])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 12
        bottomRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [statusLabel, dictateButton, bottomRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            dictateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    /// Reflect readiness / hold state in the primary button. Single source of
    /// truth for enabled state and colour so taps never hit a dead engine.
    private func updateButton() {
        let ready = engine != nil && modelsReady
        dictateButton.isEnabled = ready
        if isHolding {
            dictateButton.backgroundColor = .systemRed
            dictateButton.setTitle("Listening… release to insert", for: .normal)
        } else if ready {
            dictateButton.backgroundColor = .systemBlue
            dictateButton.setTitle("Hold to talk", for: .normal)
        } else {
            dictateButton.backgroundColor = .systemGray3
            dictateButton.setTitle(
                engine == nil ? "Keyboard unavailable" : "Set up in the Local Flow app",
                for: .normal
            )
        }
        hintLabel.isHidden = !ready
    }

    // MARK: - Engine

    private func bootstrapEngine() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            statusLabel.text = "App Group unavailable."
            updateButton()
            return
        }
        let dataDir = container.appendingPathComponent("LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        engine = KeyboardEngine(dataDirectory: dataDir.path)
        engine?.loadModels()
        refreshStatus()
    }

    private var modelsReady: Bool {
        UserDefaults(suiteName: appGroup)?.bool(forKey: "modelsReady") ?? false
    }

    private func refreshStatus() {
        if engine == nil {
            statusLabel.text = "Native engine missing."
        } else if !modelsReady {
            statusLabel.text = "Open Local Flow to download the models."
        } else {
            statusLabel.text = "Ready."
        }
        updateButton()
    }

    // MARK: - Actions

    @objc private func switchKeyboard() {
        advanceToNextInputMode()
    }

    @objc private func touchDown() {
        guard let engine, modelsReady, engine.startHold() else {
            refreshStatus()
            return
        }
        holdFeedback.impactOccurred()
        isHolding = true
        statusLabel.text = "Listening…"
        updateButton()
        startAudio(engine: engine)
    }

    @objc private func touchUp() {
        guard isHolding else { return }
        isHolding = false
        stopAudio()
        statusLabel.text = "Transcribing…"
        updateButton()
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = self?.engine?.endHold(beforeText: before) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                if text.isEmpty {
                    self.statusLabel.text = "No speech detected."
                } else {
                    self.textDocumentProxy.insertText(text)
                    self.statusLabel.text = "Inserted."
                }
                self.updateButton()
            }
        }
    }

    // MARK: - Audio

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
            updateButton()
        }
    }

    private func stopAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
