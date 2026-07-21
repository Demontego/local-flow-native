import AppKit
import Foundation

enum ScreenCapture {
    /// Frontmost window PNG → ~/.cache/local-flow-native/shots/ (last 3 kept).
    static func captureFrontWindow() -> String? {
        let shots = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/local-flow-native/shots")
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let path = shots.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970 * 1000)).png")

        guard let windowId = frontmostWindowId() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-l", String(windowId), "-x", path.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 100
        else {
            try? FileManager.default.removeItem(at: path)
            return nil
        }
        prune(shots)
        return path.path
    }

    private static func frontmostWindowId() -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in info {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            let bounds = w[kCGWindowBounds as String] as? [String: Any]
            let h = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            let wd = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            if h < 80 || wd < 80 { continue }
            if let num = w[kCGWindowNumber as String] as? Int { return num }
        }
        return nil
    }

    private static func prune(_ dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let shots = files
            .filter { $0.lastPathComponent.hasPrefix("shot-") }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return d0 > d1
            }
        for old in shots.dropFirst(3) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
