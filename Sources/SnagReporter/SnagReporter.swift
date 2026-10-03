import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

/// Opens your app's SnagFrog report page in the browser, after uploading logs,
/// diagnostics and (optionally) a snapshot of the key window.
///
/// ```swift
/// let snag = SnagReporter(appSlug: "hourslip", publicKey: "snag_pk_…",
///                         baseURL: URL(string: "https://snagfrog.com")!)
/// Task { await snag.report(logFiles: [logURL]) }
/// ```
public struct SnagReporter: Sendable {
    public let appSlug: String
    public let publicKey: String
    public let baseURL: URL
    /// Only the tail of each log file is sent.
    public var maxLogBytes: Int = 512 * 1024

    /// The server accepts at most this many files per session (snapshot included).
    public static let maxFiles = 4
    /// Raw bytes across all files. Base64 grows this by a third, which keeps the request under
    /// Netlify's 6 MB body limit.
    public static let maxTotalBytes = 4_400_000
    /// The server's per-file limit.
    public static let maxFileBytes = 4 * 1024 * 1024
    public var session: URLSession

    public init(appSlug: String, publicKey: String, baseURL: URL, session: URLSession = .shared) {
        self.appSlug = appSlug
        self.publicKey = publicKey
        self.baseURL = baseURL
        self.session = session
    }

    /// Collects context, uploads it, and opens the report page.
    /// If the upload fails, the page still opens with diagnostics in the URL.
    /// - Parameters:
    ///   - includeCrashReport: attach the app's newest crash report from the last 7 days, if macOS
    ///     wrote one and the app can read it (not in the App Sandbox).
    ///   - showsProgress: show a small SnagFrog panel while logs upload.
    @MainActor
    @discardableResult
    public func report(
        logFiles: [URL] = [],
        extraDiagnostics: [String: String] = [:],
        includeWindowSnapshot: Bool = true,
        includeCrashReport: Bool = true,
        showsProgress: Bool = true
    ) async -> URL {
        var diagnostics = Self.defaultDiagnostics()
        var logs = Self.newestFirst(logFiles).compactMap { Self.tail(of: $0, maxBytes: maxLogBytes) }
        // A recent crash report goes first, so it survives when logs are dropped to fit.
        if includeCrashReport, let crash = Self.latestCrash() {
            let context = Self.crashContext(crash)
            diagnostics.merge(context.diagnostics) { _, new in new }
            if let attachment = context.attachment { logs.insert(attachment, at: 0) }
        }
        diagnostics.merge(extraDiagnostics) { _, new in new }
        // Snapshot first, so the progress panel is never part of it.
        let snapshot = includeWindowSnapshot ? Self.keyWindowSnapshot() : nil
        let attachments = Self.fitForUpload(logs: logs, snapshot: snapshot)

        #if canImport(AppKit)
        let progress = showsProgress ? SnagProgressPanel.show() : nil
        #endif

        let url: URL
        do {
            url = try await createSession(diagnostics: diagnostics, files: attachments)
        } catch {
            Self.log.error("SnagFrog session upload failed, opening the plain report page: \(String(describing: error), privacy: .public)")
            #if DEBUG
            print("[SnagReporter] session upload failed: \(error)")
            #endif
            url = reportPageURL(diagnostics: diagnostics)
        }
        #if canImport(AppKit)
        progress?.close()
        NSWorkspace.shared.open(url)
        #endif
        return url
    }

    static let log = Logger(subsystem: "com.snagfrog.SnagReporter", category: "upload")

    /// Orders log files newest first (by modification date), so the oldest are dropped first.
    static func newestFirst(_ files: [URL]) -> [URL] {
        let dated = files.enumerated().map { index, url in
            (index, url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        return dated.sorted { a, b in
            switch (a.2, b.2) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.0 < b.0
            }
        }.map { $0.1 }
    }

    /// Trims attachments to what the server accepts: at most `maxFiles` files including the
    /// snapshot, and `maxTotalBytes` in total. The snapshot is kept; logs past the file limit are
    /// dropped (they come in priority order, newest first), and the rest share the remaining
    /// budget, each keeping the tail of its log.
    static func fitForUpload(
        logs: [Attachment],
        snapshot: Attachment?,
        maxFiles: Int = maxFiles,
        maxTotalBytes: Int = maxTotalBytes,
        maxFileBytes: Int = maxFileBytes
    ) -> [Attachment] {
        let snap = snapshot.flatMap { $0.data.count <= min(maxFileBytes, maxTotalBytes) ? $0 : nil }
        var budget = maxTotalBytes - (snap?.data.count ?? 0)
        let kept = Array(logs.prefix(max(0, maxFiles - (snap == nil ? 0 : 1))))

        // Smallest first, so short logs keep everything and long ones split what's left.
        var sized = [Int: Attachment]()
        let order = kept.indices.sorted { kept[$0].data.count < kept[$1].data.count }
        for (n, i) in order.enumerated() {
            let share = budget / (order.count - n)
            let limit = min(share, maxFileBytes)
            let log = kept[i]
            let trimmed = log.data.count <= limit
                ? log
                : Attachment(filename: log.filename, contentType: log.contentType, data: Data(log.data.suffix(limit)))
            budget -= trimmed.data.count
            if !trimmed.data.isEmpty || log.data.isEmpty { sized[i] = trimmed }
        }
        var result = kept.indices.compactMap { sized[$0] }
        if let snap { result.append(snap) }
        return result
    }

    /// Uploads context and returns the report page URL bound to it.
    public func createSession(diagnostics: [String: String], files: [Attachment]) async throws -> URL {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/sessions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SessionRequest(diagnostics: diagnostics, files: files))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SnagError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
        guard let url = URL(string: decoded.url) else { throw SnagError.invalidResponse }
        return url
    }

    /// The plain report page with diagnostics as query parameters. Needs no network call.
    public func reportPageURL(diagnostics: [String: String] = [:]) -> URL {
        let shortKeys = ["app_version": "v", "build": "build", "os_version": "os",
                         "device_model": "model", "arch": "arch", "locale": "locale"]
        var components = URLComponents(
            url: baseURL.appendingPathComponent("r").appendingPathComponent(appSlug),
            resolvingAgainstBaseURL: false
        )!
        let items = diagnostics.sorted { $0.key < $1.key }.map { key, value in
            URLQueryItem(name: shortKeys[key] ?? "d_\(key)", value: value)
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    public static func defaultDiagnostics(bundle: Bundle = .main) -> [String: String] {
        var d: [String: String] = [:]
        let info = bundle.infoDictionary ?? [:]
        d["app_version"] = info["CFBundleShortVersionString"] as? String
        d["build"] = info["CFBundleVersion"] as? String
        d["bundle_id"] = bundle.bundleIdentifier
        let v = ProcessInfo.processInfo.operatingSystemVersion
        d["os_version"] = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        d["device_model"] = sysctlString("hw.model")
        #if arch(arm64)
        d["arch"] = "arm64"
        #elseif arch(x86_64)
        d["arch"] = ProcessInfo.processInfo.isTranslated ? "x86_64 (Rosetta)" : "x86_64"
        #endif
        d["locale"] = Locale.current.identifier
        d["memory_gb"] = String(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return d.compactMapValues { $0 }
    }

    /// Reads at most `maxBytes` from the end of a file.
    public static func tail(of file: URL, maxBytes: Int) -> Attachment? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            let name = file.pathExtension.isEmpty ? "\(file.lastPathComponent).log" : file.lastPathComponent
            return Attachment(filename: name, contentType: "text/plain", data: data)
        } catch {
            return nil
        }
    }

    @MainActor
    static func keyWindowSnapshot() -> Attachment? {
        #if canImport(AppKit)
        // NSApp is nil (and force-unwrapped) outside an NSApplication, e.g. in a command-line tool.
        guard let app = NSApp,
              let view = (app.keyWindow ?? app.mainWindow)?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        return Attachment(filename: "window.jpg", contentType: "image/jpeg", data: jpeg)
        #else
        return nil
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

public struct Attachment: Sendable, Encodable, Equatable {
    public let filename: String
    public let contentType: String
    public let data: Data

    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }

    enum CodingKeys: String, CodingKey { case filename, contentType, data }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filename, forKey: .filename)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(data.base64EncodedString(), forKey: .data)
    }
}

public enum SnagError: Error, Equatable {
    case server(Int)
    case invalidResponse
}

struct SessionRequest: Encodable {
    let diagnostics: [String: String]
    let files: [Attachment]
}

struct SessionResponse: Decodable {
    let token: String
    let url: String
}

private extension ProcessInfo {
    var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }
}
