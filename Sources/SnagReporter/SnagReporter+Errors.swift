import Foundation

/// What `/api/v1/errors` accepts.
struct ErrorRequest: Encodable {
    let kind: String
    let message: String
    let stack: String?
    let version: String?
    let os: String?
    let context: [String: String]
}

extension SnagReporter {
    static let lastCrashSentKey = "SnagReporter.lastCrashSent"
    /// Frames of the crashed thread that are sent.
    static let maxCrashFrames = 40

    /// Sends one error to the app's Errors tab in SnagFrog, where identical ones are grouped and
    /// counted. Nothing is shown to the person using the app and nothing identifies them: no name,
    /// email address or files. The home folder is replaced with `~` in the message and the stack.
    ///
    /// Only call this if your privacy policy says the app reports errors on its own.
    ///
    /// ```swift
    /// do { try save() } catch { Task { try? await snag.send(error: "\(error)") } }
    /// ```
    public func send(
        error message: String,
        stack: String? = nil,
        isCrash: Bool = false,
        context: [String: String] = [:]
    ) async throws {
        let details = Self.defaultDiagnostics()
        let body = ErrorRequest(
            kind: isCrash ? "crash" : "error",
            message: String(Self.scrubHome(message).prefix(500)),
            stack: stack.map { String(Self.scrubHome($0).prefix(8000)) },
            version: details["app_version"],
            os: details["os_version"],
            context: context
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/errors"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SnagError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Call once at launch to report a crash on its own, without asking: if macOS wrote a crash
    /// report for the app since the last check, its exception and the crashed thread's frames are
    /// sent to the Errors tab. Each crash is sent once. The crash file itself is not uploaded.
    ///
    /// This is off unless you call it. Use `offerReportAfterCrash` instead to ask first, and only
    /// use this one if your privacy policy says the app reports crashes automatically. A sandboxed
    /// app cannot read crash reports, so there it does nothing.
    ///
    /// - Returns: true if a crash was sent.
    @discardableResult
    public func sendCrashAutomatically(defaults: UserDefaults = .standard) async -> Bool {
        guard let crash = Self.latestCrash() else { return false }
        let lastSent = defaults.object(forKey: Self.lastCrashSentKey) as? Date
        guard Self.isNewCrash(crash, lastSeen: lastSent) else { return false }
        let stack = Self.head(of: crash.file, maxBytes: Self.maxCrashBytes).flatMap(Self.crashedThreadStack)
        do {
            try await send(error: crash.summary ?? "Crash", stack: stack, isCrash: true)
        } catch {
            // Not marked as sent: the next launch tries again while the crash is still recent.
            return false
        }
        defaults.set(crash.date, forKey: Self.lastCrashSentKey)
        return true
    }

    /// The crashed thread of an `.ips` crash report, one frame per line in the form macOS prints
    /// them ("0  MyApp  0x1a2b  Timer.resume() + 12"). Nil when the file has no such thread.
    static func crashedThreadStack(_ data: Data) -> String? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let body = parseBody(data[data.index(after: newline)...]),
              let threads = body["threads"] as? [[String: Any]],
              let thread = threads.first(where: { $0["triggered"] as? Bool == true }),
              let frames = thread["frames"] as? [[String: Any]], !frames.isEmpty
        else { return nil }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let lines = frames.prefix(maxCrashFrames).enumerated().map { index, frame -> String in
            let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "???"
            let offset = String((frame["imageOffset"] as? Int) ?? 0, radix: 16)
            guard let symbol = frame["symbol"] as? String else { return "\(index)  \(image)  0x\(offset)  ???" }
            return "\(index)  \(image)  0x\(offset)  \(symbol) + \((frame["symbolLocation"] as? Int) ?? 0)"
        }
        return lines.joined(separator: "\n")
    }
}
