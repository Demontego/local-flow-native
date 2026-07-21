// Scaffold — compile inside Keyboard Extension target.
// Demonstrates the intended UniFFI call shape.

import Foundation

#if false // enable when UniFFI Swift module is linked
import local_flow_ffi

enum KeyboardHost {
    static let engine = LocalFlowEngine()

    static func warm() {
        _ = try? engine.loadModels()
    }

    static func dictate(pcm: [Float], proxy: UITextDocumentProxy) {
        try? engine.startHold()
        try? engine.pushAudio(samples: pcm)
        let ctx = FfiContext(
            appName: "keyboard",
            bundleId: "ai.localflow.keyboard",
            channelHint: "",
            beforeText: proxy.documentContextBeforeInput ?? "",
            selectedText: "",
            chatLines: [],
            recent: [],
            screenshotPath: nil
        )
        if let result = try? engine.endHold(ctx: ctx) {
            let text = result.clean.isEmpty ? result.raw : result.clean
            proxy.insertText(text)
        }
    }
}
#endif
