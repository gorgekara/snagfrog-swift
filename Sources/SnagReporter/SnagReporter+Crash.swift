import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A crash report macOS wrote for this app.
public struct CrashReport: Sendable, Equatable {
    public let file: URL
    /// When the crash file was written.
    public let date: Date
    /// For example "EXC_BAD_ACCESS (SIGSEGV)". Nil if the file could not be parsed.
    public let summary: String?
}

extension SnagReporter {
    /// Crash reports older than this are ignored.
    public static let crashLookback: TimeInterval = 7 * 24 * 60 * 60
    /// Crash files are JSON; only this much of the start is sent.
    static let maxCrashBytes = 1024 * 1024
    static let lastCrashSeenKey = "SnagReporter.lastCrashSeen"

    /// Where macOS writes crash reports for the current user. A sandboxed app cannot read this
    /// folder, so there `latestCrash` returns nil and reports work as they do without it.
    public static var crashDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// The newest crash report for this app written after `since`, or nil.
    public static func latestCrash(
        processName: String = ProcessInfo.processInfo.processName,
        in directory: URL = crashDirectory,
        since: Date = Date().addingTimeInterval(-crashLookback)
    ) -> CrashReport? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = files.compactMap { url -> (URL, Date)? in
            guard ["ips", "crash"].contains(url.pathExtension.lowercased()),
                  url.lastPathComponent.hasPrefix(processName + "-") || url.lastPathComponent.hasPrefix(processName + "_"),
                  let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate,
                  date > since else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }

        for (url, date) in candidates {
            guard let data = head(of: url, maxBytes: maxCrashBytes) else { continue }
            let parsed = parseCrash(data)
            // "MyApp-" also prefixes "MyApp-Helper-…": when the file names its process, it must match.
            if let name = parsed.processName, name != processName { continue }
            // Hangs and other diagnostics share the folder; 309 is a crash.
            if let type = parsed.bugType, type != "309" { continue }
            return CrashReport(file: url, date: date, summary: parsed.summary)
        }
        return nil
    }

    /// Reads the process name, report type and exception out of an `.ips` file: one line of JSON
    /// metadata, then a JSON body. Older `.crash` text files yield only the exception line.
    static func parseCrash(_ data: Data) -> (processName: String?, bugType: String?, summary: String?) {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline]) as? [String: Any]
        else {
            let text = String(decoding: data.prefix(16 * 1024), as: UTF8.self)
            let line = text.split(separator: "\n").first { $0.hasPrefix("Exception Type:") }
            let summary = line.map { $0.dropFirst("Exception Type:".count).trimmingCharacters(in: .whitespaces) }
            return (nil, nil, summary?.isEmpty == false ? summary : nil)
        }
        let body = parseBody(data[data.index(after: newline)...])
        let exception = body?["exception"] as? [String: Any]
        var summary = exception?["type"] as? String
        if let signal = exception?["signal"] as? String {
            summary = summary.map { "\($0) (\(signal))" } ?? signal
        }
        return (header["app_name"] as? String ?? header["name"] as? String, header["bug_type"] as? String, summary)
    }

    /// The JSON body of an `.ips` file. macOS appends a plain-text "System Profile:" section
    /// after it, so when the whole text is not JSON, the body is taken to end at a closing brace
    /// at the start of a line (the body is pretty-printed, so only its own closing brace sits there).
    static func parseBody(_ data: Data) -> [String: Any]? {
        if let whole = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return whole }
        let text = String(decoding: data, as: UTF8.self)
        var searchEnd = text.endIndex
        for _ in 0..<20 {
            guard let close = text.range(of: "\n}", options: .backwards, range: text.startIndex..<searchEnd) else { return nil }
            if let body = try? JSONSerialization.jsonObject(with: Data(text[..<close.upperBound].utf8)) as? [String: Any] {
                return body
            }
            searchEnd = close.lowerBound
        }
        return nil
    }

    /// Reads at most `maxBytes` from the start of a file.
    static func head(of file: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    /// The crash file as an upload, plus the details that mark the report as a crash.
    static func crashContext(_ crash: CrashReport) -> (attachment: Attachment?, diagnostics: [String: String]) {
        let attachment = head(of: crash.file, maxBytes: maxCrashBytes).map {
            Attachment(filename: crash.file.lastPathComponent, contentType: "text/plain", data: $0)
        }
        return (attachment, [
            "crash": crash.summary ?? "Crash log attached",
            "crash_time": ISO8601DateFormatter().string(from: crash.date)
        ])
    }

    /// Whether a crash is new since the last time we looked. On first use only a crash from the
    /// last day counts, so adopting this does not prompt about an old crash.
    static func isNewCrash(_ crash: CrashReport, lastSeen: Date?, now: Date = Date()) -> Bool {
        crash.date > (lastSeen ?? now.addingTimeInterval(-24 * 60 * 60))
    }

    #if canImport(AppKit)
    /// Call once at launch. If the app crashed since the last check, asks the user whether to
    /// send a report and, if so, opens the report page with the crash log attached.
    ///
    /// ```swift
    /// Task { await snag.offerReportAfterCrash(logFiles: [logFileURL]) }
    /// ```
    ///
    /// - Returns: true if the user chose to send a report.
    @MainActor
    @discardableResult
    public func offerReportAfterCrash(
        logFiles: [URL] = [],
        defaults: UserDefaults = .standard
    ) async -> Bool {
        guard let crash = Self.latestCrash() else { return false }
        let lastSeen = defaults.object(forKey: Self.lastCrashSeenKey) as? Date
        guard Self.isNewCrash(crash, lastSeen: lastSeen) else { return false }
        // Remember it either way, so the question is asked once per crash.
        defaults.set(crash.date, forKey: Self.lastCrashSeenKey)

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        let alert = NSAlert()
        alert.messageText = "\(appName) quit unexpectedly"
        alert.informativeText = "Would you like to send a report? The crash log is attached, and you can review it before sending."
        alert.addButton(withTitle: "Send Report…")
        alert.addButton(withTitle: "Not Now")
        alert.icon = Self.icon(size: 64)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        await report(
            logFiles: logFiles, extraDiagnostics: ["crash_prompt": "yes"],
            includeWindowSnapshot: false, includeCrashReport: true
        )
        return true
    }
    #endif
}
