// SessionManager.swift
// Creates, writes to, and parses Markdown transcript files.

import Foundation
import Combine

struct TranscriptEntry: Identifiable, Hashable {
    var id = UUID()
    let timestamp: Date
    var text: String

    var minuteLabel: String {
        timestamp.formatted(.dateTime.hour().minute())
    }
}

struct CaptionSession: Identifiable, Hashable, Comparable {
    let id: UUID
    let fileURL: URL
    let date: Date
    var title: String? = nil

    /// Custom title if the user renamed the session, otherwise the formatted date.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d · HH:mm"
        return fmt.string(from: date)
    }

    /// The date/time label, shown as a subtitle when a custom title is set.
    var dateLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d · HH:mm"
        return fmt.string(from: date)
    }

    var shortDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    static func < (lhs: CaptionSession, rhs: CaptionSession) -> Bool {
        lhs.date > rhs.date // Newest first
    }
}

@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [CaptionSession] = []

    /// Canonical 24-hour formatter used for the `## HH:mm` headings written into files.
    private static let headingTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Parses a heading time string into a `Date` on the given day. Tolerant of both
    /// 24-hour ("22:35") and locale 12-hour ("2:35 PM") formats, and of the narrow /
    /// non-breaking spaces that locale formatting inserts before AM/PM.
    static func parseHeadingTime(_ raw: String, onDay day: Date) -> Date? {
        let cleaned = raw
            .replacingOccurrences(of: "\u{202f}", with: " ")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespaces)

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["HH:mm", "h:mm a", "h:mma", "H:mm"] {
            fmt.dateFormat = pattern
            if let t = fmt.date(from: cleaned) ?? fmt.date(from: cleaned.uppercased()) {
                let c = Calendar.current.dateComponents([.hour, .minute], from: t)
                return Calendar.current.date(
                    bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: day
                )
            }
        }
        return nil
    }

    // MARK: - Output directory

    private var outputDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("livescriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Session lifecycle

    /// Creates a new .md file for a session and writes the header. Returns the file URL.
    func createNewSession(deviceName: String, duration: AppModel.SessionDuration) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())
        let filename = "Caption_\(stamp).md"
        let url = outputDirectory.appendingPathComponent(filename)

        let displayDate = Date().formatted(date: .abbreviated, time: .shortened)
        let durationText = duration == .unlimited ? "No limit" : duration.rawValue

        var header = "# Live Caption — \(displayDate)\n\n"
        header += "**Audio Device:** \(deviceName)  \n"
        header += "**Duration Target:** \(durationText)  \n\n"
        header += "---\n\n"

        try? header.write(to: url, atomically: true, encoding: .utf8)
        reloadSessions()
        return url
    }

    /// Appends a single transcript entry to the open file (new timestamp heading).
    func appendEntry(_ entry: TranscriptEntry, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()

        let time = Self.headingTimeFormatter.string(from: entry.timestamp)
        let block = "\n## \(time)\n\(entry.text)"
        if let data = block.data(using: .utf8) { handle.write(data) }
    }

    /// Appends continuation text within the same minute (no new heading).
    func appendContinuation(_ text: String, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        if let data = (" " + text).data(using: .utf8) { handle.write(data) }
    }

    /// Writes a footer with session end time and duration.
    func finalizeSession(at url: URL, startTime: Date?, endTime: Date) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()

        var footer = "\n---\n\n"
        footer += "*Session ended at \(endTime.formatted(.dateTime.hour().minute().second()))"
        if let start = startTime {
            let elapsed = Int(endTime.timeIntervalSince(start))
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            footer += " — Duration: \(minutes)m \(seconds)s"
        }
        footer += "*\n"

        if let data = footer.data(using: .utf8) { handle.write(data) }
        reloadSessions()
    }

    // MARK: - Session listing

    func reloadSessions() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        sessions = contents
            .filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("Caption_") }
            .compactMap { url -> CaptionSession? in
                let name = url.deletingPathExtension().lastPathComponent
                let remainder = String(name.dropFirst("Caption_".count))
                // The timestamp is the fixed-width leading portion "yyyy-MM-dd_HH-mm-ss".
                let stamp = String(remainder.prefix(19))
                guard let date = formatter.date(from: stamp) else { return nil }
                // An optional custom title follows a "__" delimiter.
                var title: String? = nil
                if let range = remainder.range(of: "__") {
                    let t = String(remainder[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { title = t }
                }
                return CaptionSession(id: UUID(), fileURL: url, date: date, title: title)
            }
            .sorted()
    }

    /// Renames a session by rewriting its filename, keeping the timestamp prefix so
    /// date sorting still works. An empty title clears any custom name.
    func renameSession(_ session: CaptionSession, to rawTitle: String) {
        let name = session.fileURL.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("Caption_") else { return }
        let remainder = String(name.dropFirst("Caption_".count))
        let stamp = String(remainder.prefix(19))

        let title = Self.sanitizeTitle(rawTitle)
        let base = title.isEmpty ? "Caption_\(stamp)" : "Caption_\(stamp)__\(title)"
        let newURL = session.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(base)
            .appendingPathExtension("md")

        if newURL != session.fileURL {
            try? FileManager.default.moveItem(at: session.fileURL, to: newURL)
        }
        reloadSessions()
    }

    /// Strips characters that are illegal or ambiguous in our filename scheme.
    private static func sanitizeTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        t = t.components(separatedBy: illegal).joined()
        // Reserve "__" as the title delimiter.
        while t.contains("__") { t = t.replacingOccurrences(of: "__", with: "_") }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Moves a session's transcript file to the Trash and refreshes the list.
    func deleteSession(_ session: CaptionSession) {
        try? FileManager.default.trashItem(at: session.fileURL, resultingItemURL: nil)
        reloadSessions()
    }

    // MARK: - Session parsing (for sidebar preview)

    func parseEntries(from url: URL) -> [TranscriptEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries: [TranscriptEntry] = []
        let lines = content.components(separatedBy: "\n")

        let today = Calendar.current.startOfDay(for: Date())

        var currentDate: Date?
        var currentText = ""

        for line in lines {
            if line.hasPrefix("## ") {
                // Save previous
                if let d = currentDate, !currentText.isEmpty {
                    entries.append(TranscriptEntry(timestamp: d, text: currentText.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                let timeStr = String(line.dropFirst(3))
                currentDate = Self.parseHeadingTime(timeStr, onDay: today)
                currentText = ""
            } else if currentDate != nil,
                      !line.hasPrefix("#"), !line.hasPrefix("---"),
                      !line.hasPrefix("**"), !line.hasPrefix("*Session"),
                      !line.isEmpty {
                currentText += (currentText.isEmpty ? "" : " ") + line
            }
        }
        if let d = currentDate, !currentText.isEmpty {
            entries.append(TranscriptEntry(timestamp: d, text: currentText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return entries
    }

    var outputPath: String { outputDirectory.path }
}
