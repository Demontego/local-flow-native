import AppKit

/// Local Hub: stats, history, scratch notes, dictionary.
final class HubWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let engine: EngineBridge
    private var window: NSWindow!
    private var segment: NSSegmentedControl!
    private var text: NSTextView!
    private var table: NSTableView!
    private var scroll: NSScrollView!
    private var status: NSTextField!
    private var sessions: [[String: Any]] = []
    private var notes: [[String: Any]] = []
    private var dictRows: [(String, String)] = []
    private var onDictateScratch: (() -> Void)?
    private var onLearnSelection: (() -> Void)?

    init(
        engine: EngineBridge,
        onDictateScratch: @escaping () -> Void,
        onLearnSelection: @escaping () -> Void
    ) {
        self.engine = engine
        self.onDictateScratch = onDictateScratch
        self.onLearnSelection = onLearnSelection
        super.init()
        build()
    }

    func show() {
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let rect = NSRect(x: 0, y: 0, width: 520, height: 420)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Local Flow Hub"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: rect)
        window.contentView = content

        segment = NSSegmentedControl(labels: ["Home", "History", "Notes", "Dictionary"], trackingMode: .selectOne, target: self, action: #selector(segmentChanged))
        segment.frame = NSRect(x: 16, y: 380, width: 360, height: 24)
        segment.selectedSegment = 0
        content.addSubview(segment)

        let refreshBtn = NSButton(frame: NSRect(x: 390, y: 378, width: 110, height: 28))
        refreshBtn.title = "Refresh"
        refreshBtn.bezelStyle = .rounded
        refreshBtn.target = self
        refreshBtn.action = #selector(refresh)
        content.addSubview(refreshBtn)

        text = NSTextView(frame: NSRect(x: 0, y: 0, width: 488, height: 280))
        text.isEditable = false
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 8, height: 8)

        table = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.title = "Items"
        col.width = 460
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22

        scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: 488, height: 310))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        content.addSubview(scroll)

        status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 16, y: 28, width: 488, height: 20)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        content.addSubview(status)

        let scratch = NSButton(frame: NSRect(x: 16, y: 8, width: 150, height: 28))
        scratch.title = "Dictate to Scratch"
        scratch.bezelStyle = .rounded
        scratch.target = self
        scratch.action = #selector(dictateScratch)
        content.addSubview(scratch)

        let learn = NSButton(frame: NSRect(x: 176, y: 8, width: 160, height: 28))
        learn.title = "Learn from selection"
        learn.bezelStyle = .rounded
        learn.target = self
        learn.action = #selector(learnSelection)
        content.addSubview(learn)

        let copy = NSButton(frame: NSRect(x: 346, y: 8, width: 70, height: 28))
        copy.title = "Copy"
        copy.bezelStyle = .rounded
        copy.target = self
        copy.action = #selector(copySelected)
        content.addSubview(copy)

        let del = NSButton(frame: NSRect(x: 424, y: 8, width: 80, height: 28))
        del.title = "Delete"
        del.bezelStyle = .rounded
        del.target = self
        del.action = #selector(deleteSelected)
        content.addSubview(del)
    }

    @objc private func segmentChanged() {
        applySegment()
    }

    @objc func refresh() {
        guard let data = engine.hubSnapshotJSON().data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            status.stringValue = "Hub snapshot failed"
            return
        }
        sessions = (obj["sessions"] as? [[String: Any]]) ?? []
        notes = (obj["notes"] as? [[String: Any]]) ?? []
        let stats = obj["stats"] as? [String: Any] ?? [:]
        let p = engine.personalization()
        dictRows = p.dictionary.map { ($0.heard, $0.replace_with) }
        status.stringValue =
            "Today \(stats["words_today"] ?? 0) words · week \(stats["words_week"] ?? 0) · streak \(stats["streak_days"] ?? 0)d · sessions \(stats["sessions_today"] ?? 0)"
        applySegment()
    }

    private func applySegment() {
        switch segment.selectedSegment {
        case 0:
            scroll.documentView = text
            let p = engine.personalization()
            let last = sessions.first?["preview"] as? String ?? "—"
            text.string = """
            Local Flow Hub

            Words today: see status bar
            Last session: \(last)

            Dictionary rules: \(p.dictionary.count)
            Scratch notes: \(notes.count)
            Sessions logged: \(sessions.count)

            Tip: tap fn to dictate · Ctrl+Option hold still works.
            Use “Dictate to Scratch” then tap fn — no paste.
            """
        case 1:
            scroll.documentView = table
            table.reloadData()
        case 2:
            scroll.documentView = table
            table.reloadData()
        case 3:
            scroll.documentView = table
            table.reloadData()
        default:
            break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch segment.selectedSegment {
        case 1: return sessions.count
        case 2: return notes.count
        case 3: return dictRows.count
        default: return 0
        }
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        switch segment.selectedSegment {
        case 1:
            let s = sessions[row]
            let prev = s["preview"] as? String ?? ""
            let mode = s["mode"] as? String ?? ""
            let words = s["word_count"] ?? ""
            return "[\(mode)] \(words)w  \(prev)"
        case 2:
            return notes[row]["text"] as? String ?? ""
        case 3:
            let r = dictRows[row]
            return "\(r.0) → \(r.1)"
        default:
            return nil
        }
    }

    @objc private func dictateScratch() {
        onDictateScratch?()
        status.stringValue = "Scratch mode on — tap fn to dictate a note"
    }

    @objc private func learnSelection() {
        onLearnSelection?()
    }

    @objc private func copySelected() {
        let row = table.selectedRow
        var clip = ""
        switch segment.selectedSegment {
        case 1 where row >= 0 && row < sessions.count:
            clip = sessions[row]["preview"] as? String ?? ""
        case 2 where row >= 0 && row < notes.count:
            clip = notes[row]["text"] as? String ?? ""
        case 3 where row >= 0 && row < dictRows.count:
            clip = "\(dictRows[row].0) → \(dictRows[row].1)"
        case 0:
            clip = text.string
        default:
            break
        }
        guard !clip.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clip, forType: .string)
        status.stringValue = "Copied"
    }

    @objc private func deleteSelected() {
        guard segment.selectedSegment == 2 else {
            status.stringValue = "Delete applies to Notes"
            return
        }
        let row = table.selectedRow
        guard row >= 0, row < notes.count, let id = notes[row]["id"] as? String else { return }
        let r = engine.deleteScratchNote(id: id)
        status.stringValue = r == "ok" ? "Deleted" : r
        refresh()
    }
}
