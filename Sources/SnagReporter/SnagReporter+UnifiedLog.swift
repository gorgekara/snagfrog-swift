import Foundation
import OSLog

extension SnagReporter {
    /// Attaches what the app wrote to macOS's unified log (`Logger`, `os_log`) to a report, for
    /// apps that keep no log file of their own.
    ///
    /// ```swift
    /// Task { await snag.report(unifiedLog: .app) }
    /// NSApp.helpMenu?.addItem(snag.menuItem(unifiedLog: .app))
    /// ```
    ///
    /// Only this app's own process is read, and only since it was launched: macOS does not let an
    /// app read other apps' entries, or its own from an earlier launch. Values the app did not
    /// mark `privacy: .public` appear as `<private>`, as they do in Console; an entry that is
    /// nothing else (every `NSLog` message) is left out.
    public struct UnifiedLog: Sendable, Equatable {
        /// Subsystems to include. Each also matches its dotted children: `com.acme.app` covers
        /// `com.acme.app.network`. `nil` means the app's bundle identifier.
        public var subsystems: [String]?
        /// How far back to go, in seconds.
        public var duration: TimeInterval
        /// Include entries with no subsystem, which is how `Logger()` writes. (`NSLog` writes that
        /// way too, but macOS hides its text, so those entries are left out either way.)
        public var includesUnlabeled: Bool

        public init(subsystems: [String]? = nil, last duration: TimeInterval = 15 * 60, includesUnlabeled: Bool = true) {
            self.subsystems = subsystems
            self.duration = duration
            self.includesUnlabeled = includesUnlabeled
        }

        /// The app's own entries from the last 15 minutes.
        public static let app = UnifiedLog()

        /// Whether an entry with this subsystem belongs in the report.
        func includes(subsystem: String, bundleID: String?) -> Bool {
            if subsystem.isEmpty { return includesUnlabeled }
            guard let wanted = subsystems ?? bundleID.map({ [$0] }) else {
                // No bundle identifier (a command-line tool) and none named: everything the
                // process logged except the system frameworks' own chatter.
                return !subsystem.hasPrefix("com.apple.")
            }
            return wanted.contains { subsystem == $0 || subsystem.hasPrefix($0 + ".") }
        }
    }

    /// One entry of the unified log, reduced to what a report shows.
    struct LogLine: Equatable, Sendable {
        let date: Date
        let level: String
        let subsystem: String
        let category: String
        let message: String
    }

    static let unifiedLogFilename = "unified-log.log"

    /// The app's recent unified log as a text attachment, or nil when there is nothing to attach
    /// (no matching entries, or the log cannot be read). Reading can take a moment in an app that
    /// logs a lot: call it off the main thread.
    static func unifiedLogAttachment(_ options: UnifiedLog, bundleID: String?, maxBytes: Int) -> Attachment? {
        guard let lines = unifiedLogLines(options, bundleID: bundleID),
              let data = renderUnifiedLog(lines, maxBytes: maxBytes) else { return nil }
        return Attachment(filename: unifiedLogFilename, contentType: "text/plain", data: data)
    }

    /// Reads this process's entries from the last `options.duration` seconds, oldest first.
    /// Returns nil when the log store cannot be opened or read.
    static func unifiedLogLines(_ options: UnifiedLog, bundleID: String?, now: Date = Date()) -> [LogLine]? {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
        let cutoff = now.addingTimeInterval(-max(0, options.duration))
        let position = store.position(date: cutoff)
        // The store filters by date itself, which is far quicker than walking a long-running app's
        // whole log. If it rejects the predicate, read everything and rely on the check below.
        let entries: AnySequence<OSLogEntry>
        if let dated = try? store.getEntries(at: position, matching: NSPredicate(format: "date >= %@", cutoff as NSDate)) {
            entries = dated
        } else if let everything = try? store.getEntries(at: position) {
            entries = everything
        } else {
            return nil
        }
        var lines: [LogLine] = []
        for case let entry as OSLogEntryLog in entries {
            // Checked again here: on some systems the position and the predicate are not honoured.
            guard entry.date >= cutoff, options.includes(subsystem: entry.subsystem, bundleID: bundleID) else { continue }
            let message = entry.composedMessage
            guard !isFullyRedacted(message) else { continue }
            lines.append(LogLine(
                date: entry.date, level: levelName(entry.level),
                subsystem: entry.subsystem, category: entry.category, message: message
            ))
        }
        return lines
    }

    /// True for an entry that says nothing once macOS has hidden its private values: every
    /// `NSLog` message, and a `Logger` message that is a single value not marked `.public`.
    /// A line reading only `<private>` helps nobody, so those are left out.
    static func isFullyRedacted(_ message: String) -> Bool {
        let rest = message.replacingOccurrences(of: "<private>", with: "")
        return rest.count != message.count && rest.allSatisfy { $0.isWhitespace || $0.isPunctuation }
    }

    /// The entries as text, one per line, newest last: `time level [subsystem:category] message`.
    /// Over `maxBytes` the oldest entries are dropped and the first line says how many.
    /// Returns nil for no entries.
    static func renderUnifiedLog(_ lines: [LogLine], maxBytes: Int, timeZone: TimeZone = .current) -> Data? {
        guard !lines.isEmpty, maxBytes > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"

        // Newest first until the budget is used, leaving room for the "left out" line.
        let budget = max(0, maxBytes - 64)
        var kept: [Data] = []
        var used = 0
        for line in lines.reversed() {
            let source = [line.subsystem, line.category].filter { !$0.isEmpty }.joined(separator: ":")
            let level = line.level.padding(toLength: 6, withPad: " ", startingAt: 0)
            let text = "\(formatter.string(from: line.date)) \(level) \(source.isEmpty ? "" : "[\(source)] ")\(line.message)\n"
            let data = Data(text.utf8)
            if used + data.count > budget {
                // Not even the newest entry fits: keep its end, where the detail usually is.
                if kept.isEmpty { return Data(data.suffix(maxBytes)) }
                break
            }
            kept.append(data)
            used += data.count
        }
        let dropped = lines.count - kept.count
        var out = Data()
        if dropped > 0 { out.append(Data("… \(dropped) earlier entries left out\n".utf8)) }
        for data in kept.reversed() { out.append(data) }
        return out
    }

    /// Crash report first (it must survive when files are dropped to fit), then the unified log,
    /// then the app's log files, newest first.
    static func assemble(crash: Attachment?, unifiedLog: Attachment?, files: [Attachment]) -> [Attachment] {
        [crash, unifiedLog].compactMap { $0 } + files
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "log"
        }
    }
}
