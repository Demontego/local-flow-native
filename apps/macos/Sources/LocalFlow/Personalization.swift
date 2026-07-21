import AppKit
import Foundation

struct PersonalizationReplacement: Codable {
    var heard: String
    var replace_with: String
}

struct PersonalizationSnippet: Codable {
    var trigger: String
    var expansion: String
}

struct PersonalizationSettings: Codable {
    var dictionary: [PersonalizationReplacement]
    var snippets: [PersonalizationSnippet]
    var app_styles: [String: String]
    var cleanup_enabled: Bool

    static let `default` = PersonalizationSettings(
        dictionary: [],
        snippets: [],
        app_styles: [:],
        cleanup_enabled: true
    )
}

enum PersonalizationEditor {
    static func addDictionaryRule(engine: EngineBridge) -> String? {
        let fields = form(
            title: "Add dictionary replacement",
            labels: ["Whisper hears", "Replace with"]
        )
        guard fields.alert.runModal() == .alertFirstButtonReturn else { return nil }
        let heard = fields.values[0].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = fields.values[1].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !replacement.isEmpty else { return "Dictionary rule needs both values" }
        var settings = engine.personalization()
        settings.dictionary.removeAll {
            $0.heard.caseInsensitiveCompare(heard) == .orderedSame
        }
        settings.dictionary.append(.init(heard: heard, replace_with: replacement))
        return engine.savePersonalization(settings)
    }

    static func addSnippet(engine: EngineBridge) -> String? {
        let fields = form(
            title: "Add voice snippet",
            labels: ["Phrase to say", "Text to insert"]
        )
        guard fields.alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trigger = fields.values[0].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = fields.values[1].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !expansion.isEmpty else { return "Snippet needs a trigger and text" }
        var settings = engine.personalization()
        settings.snippets.removeAll {
            $0.trigger.caseInsensitiveCompare(trigger) == .orderedSame
        }
        settings.snippets.append(.init(trigger: trigger, expansion: expansion))
        return engine.savePersonalization(settings)
    }

    static func setStyle(engine: EngineBridge, app: NSRunningApplication?) -> String? {
        guard let bundleID = app?.bundleIdentifier else { return "Focus an app first" }
        let alert = NSAlert()
        alert.messageText = "Writing style for \(app?.localizedName ?? bundleID)"
        alert.informativeText = "Applied only while dictating into this app."
        alert.addButton(withTitle: "Technical")
        alert.addButton(withTitle: "Casual")
        alert.addButton(withTitle: "Neutral")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        let style: String?
        switch choice {
        case .alertFirstButtonReturn: style = "concise technical"
        case .alertSecondButtonReturn: style = "casual"
        case .alertThirdButtonReturn: style = "neutral"
        default: style = nil
        }
        guard let style else { return nil }
        var settings = engine.personalization()
        settings.app_styles[bundleID] = style
        return engine.savePersonalization(settings)
    }

    static func toggleCleanup(engine: EngineBridge) -> String {
        var settings = engine.personalization()
        settings.cleanup_enabled.toggle()
        return engine.savePersonalization(settings)
    }

    static func summary(engine: EngineBridge) -> String {
        let settings = engine.personalization()
        let cleanup = settings.cleanup_enabled ? "on" : "off"
        return "Cleanup: \(cleanup) · Dictionary: \(settings.dictionary.count) · Snippets: \(settings.snippets.count) · App styles: \(settings.app_styles.count)"
    }

    private static func form(title: String, labels: [String]) -> (alert: NSAlert, values: [NSTextField]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let values = labels.map { label -> NSTextField in
            let field = NSTextField(string: "")
            field.placeholderString = label
            field.frame.size = NSSize(width: 320, height: 24)
            stack.addArrangedSubview(NSTextField(labelWithString: label))
            stack.addArrangedSubview(field)
            return field
        }
        alert.accessoryView = stack
        return (alert, values)
    }
}
