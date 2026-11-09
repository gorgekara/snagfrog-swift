#if os(iOS)
import Foundation
import MachO
import UIKit

// iOS gives an app no way to read its own crash reports, so the app records its crashes itself:
// an uncaught Objective-C exception, or a fatal signal (a Swift runtime trap, a bad memory access,
// an abort). The record is a small text file in the app's container; the next launch finds it.
//
// What a signal handler may do is very limited: no allocation, no locks, no Swift strings. So
// everything it writes is prepared at install, and it writes with open/write/close only.

/// Where the crash record goes, as a C string.
private var crashRecordPath: UnsafeMutablePointer<CChar>?
/// The lines about the app and its binary, prepared at install.
private var crashHeader: UnsafeMutablePointer<CChar>?
private var crashHeaderLength = 0
/// Set once the exception handler has written its record, so the abort that follows does not
/// overwrite it with a plain SIGABRT.
private var exceptionRecorded: sig_atomic_t = 0
private let signalSlots = 32
private var previousSignalActions: UnsafeMutablePointer<sigaction>?
private var signalSummaries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private let maxSignalFrames: Int32 = 128
private var signalFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
private var exceptionUnifiedLog: SnagReporter.UnifiedLog?
private var crashDetectionInstalled = false
/// When the previous launch started, so only a crash from that session counts.
private var previousLaunchStart: Date?

private func writeRaw(_ fd: Int32, _ text: StaticString) {
    _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

private func snagSignalHandler(_ signal: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    if exceptionRecorded == 0, let path = crashRecordPath {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            writeRaw(fd, "Crash: ")
            if signal >= 0, Int(signal) < signalSlots, let summary = signalSummaries?[Int(signal)] {
                _ = write(fd, summary, strlen(summary))
            } else {
                writeRaw(fd, "Fatal signal")
            }
            writeRaw(fd, "\n")
            if let header = crashHeader { _ = write(fd, header, crashHeaderLength) }
            writeRaw(fd, "\nStack:\n")
            if let frames = signalFrames {
                let count = backtrace(frames, maxSignalFrames)
                backtrace_symbols_fd(frames, count, fd)
            }
            close(fd)
        }
    }
    // Hand the signal on to whoever had it before: another crash reporter, or the system, which
    // ends the app (and writes the crash report you see in Xcode's Organizer).
    if signal >= 0, Int(signal) < signalSlots, let previous = previousSignalActions {
        sigaction(signal, previous + Int(signal), nil)
    } else {
        Darwin.signal(signal, SIG_DFL)
    }
    raise(signal)
}

private func snagExceptionHandler(_ exception: NSException) {
    SnagReporter.recordException(exception)
    exceptionRecorded = 1
    previousExceptionHandler?(exception)
}

extension SnagReporter {
    static let crashRecordFilename = "last-crash.crash"
    static let launchStartKey = "SnagReporter.launchStart"
    /// The unified log kept in a crash record, at most.
    static let maxCrashLogBytes = 256 * 1024

    /// Where the crash record is kept: Application Support/SnagReporter in the app's container.
    public static var crashDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("SnagReporter", isDirectory: true)
    }

    /// Call once, as early as possible at launch (`App.init`, or
    /// `application(_:didFinishLaunchingWithOptions:)`). From then on, when the app crashes it
    /// writes a short record: the exception or signal, the stack, and the app's load address
    /// for symbolication. The next launch finds it: `report()` attaches it and marks the report
    /// as a crash, `offerReportAfterCrash()` asks the person, and `sendCrashAutomatically()`
    /// sends it to the Errors tab.
    ///
    /// Handlers that were installed before (another crash reporter) still run after this one.
    /// Nothing leaves the device here.
    ///
    /// - Parameter unifiedLog: also keep the app's recent unified log in the record when the crash
    ///   is an uncaught exception, since iOS does not let the next launch read it. A crash by
    ///   signal (a Swift trap, a bad memory access) cannot read the log safely, so its record has
    ///   only the stack.
    @MainActor
    public static func installCrashDetection(unifiedLog: UnifiedLog? = nil, defaults: UserDefaults = .standard) {
        guard !crashDetectionInstalled else { return }
        crashDetectionInstalled = true
        exceptionUnifiedLog = unifiedLog
        previousLaunchStart = defaults.object(forKey: launchStartKey) as? Date
        defaults.set(Date(), forKey: launchStartKey)

        let directory = crashDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)

        crashRecordPath = strdup(directory.appendingPathComponent(crashRecordFilename).path)
        let header = crashHeaderText()
        crashHeader = strdup(header)
        crashHeaderLength = header.utf8.count

        let summaries = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: signalSlots)
        summaries.initialize(repeating: nil, count: signalSlots)
        let names: [(Int32, String)] = [
            (SIGABRT, "EXC_CRASH (SIGABRT)"),
            (SIGBUS, "EXC_BAD_ACCESS (SIGBUS)"),
            (SIGFPE, "EXC_ARITHMETIC (SIGFPE)"),
            (SIGILL, "EXC_BAD_INSTRUCTION (SIGILL)"),
            (SIGSEGV, "EXC_BAD_ACCESS (SIGSEGV)"),
            (SIGTRAP, "EXC_BREAKPOINT (SIGTRAP)")
        ]
        for (signal, name) in names { summaries[Int(signal)] = strdup(name) }
        signalSummaries = summaries

        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(maxSignalFrames))
        frames.initialize(repeating: nil, count: Int(maxSignalFrames))
        signalFrames = frames

        // A stack overflow leaves no stack to run the handler on: give the main thread a spare one.
        let altSize = 64 * 1024
        var altStack = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: altSize, alignment: 16),
                               ss_size: altSize, ss_flags: 0)
        sigaltstack(&altStack, nil)

        let previous = UnsafeMutablePointer<sigaction>.allocate(capacity: signalSlots)
        previous.initialize(repeating: sigaction(), count: signalSlots)
        previousSignalActions = previous
        for (signal, _) in names {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = snagSignalHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, previous + Int(signal))
        }

        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(snagExceptionHandler)
    }

    /// The lines under "Crash:" in a record: app, OS, model, and the binary's name, load address
    /// and UUID, which `atos` needs to turn the stack's addresses into function names.
    static func crashHeaderText(bundle: Bundle = .main) -> String {
        let d = defaultDiagnostics(bundle: bundle)
        var lines = [
            "App: \(bundle.bundleIdentifier ?? ProcessInfo.processInfo.processName) \(d["app_version"] ?? "?") (\(d["build"] ?? "?"))",
            "OS: \(d["os_version"] ?? "?")",
            "Model: \(d["device_model"] ?? "?")"
        ]
        if let image = mainImage() {
            let address = "0x" + String(image.address, radix: 16)
            lines.append("Binary: \(image.name) \(address)" + (image.uuid.map { " uuid \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The app's executable as loaded: name, load address and UUID.
    static func mainImage() -> (name: String, address: UInt, uuid: String?)? {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), header.pointee.filetype == UInt32(MH_EXECUTE) else { continue }
            let name = URL(fileURLWithPath: String(cString: _dyld_get_image_name(index))).lastPathComponent
            var uuid: String?
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let load = command.loadUnaligned(as: load_command.self)
                if load.cmd == UInt32(LC_UUID) {
                    uuid = UUID(uuid: command.loadUnaligned(as: uuid_command.self).uuid).uuidString
                    break
                }
                command = command.advanced(by: Int(load.cmdsize))
            }
            return (name, UInt(bitPattern: header), uuid)
        }
        return nil
    }

    /// Writes the record for an uncaught exception: its name and reason, the stack it carries,
    /// and, if asked for at install, the app's recent unified log.
    static func recordException(_ exception: NSException) {
        guard let path = crashRecordPath else { return }
        let reason = (exception.reason ?? "").replacingOccurrences(of: "\n", with: " ")
        let summary = reason.isEmpty ? exception.name.rawValue : "\(exception.name.rawValue): \(reason)"
        var text = "Crash: \(String(summary.prefix(500)))\n"
        if let header = crashHeader { text += String(cString: header) }
        text += "\nStack:\n" + exception.callStackSymbols.joined(separator: "\n") + "\n"
        if let options = exceptionUnifiedLog,
           let log = unifiedLogAttachment(options, bundleID: Bundle.main.bundleIdentifier, maxBytes: maxCrashLogBytes) {
            text += "\n--- Unified log ---\n" + String(decoding: log.data, as: UTF8.self)
        }
        try? Data(text.utf8).write(to: URL(fileURLWithPath: String(cString: path)), options: .atomic)
    }

    /// The crash recorded by `installCrashDetection()` if it was written after `since`, or nil.
    /// By default that is the previous session's crash, if it was in the last 7 days: a crash
    /// from two launches ago is not attached again.
    public static func latestCrash(
        in directory: URL = crashDirectory,
        since: Date = previousSessionStart()
    ) -> CrashReport? {
        let file = directory.appendingPathComponent(crashRecordFilename)
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              date > since,
              let data = head(of: file, maxBytes: 4096), !data.isEmpty else { return nil }
        return CrashReport(file: file, date: date, summary: recordedCrashSummary(data))
    }

    /// The start of the previous launch, or 7 days ago if that is later or unknown.
    public static func previousSessionStart(now: Date = Date()) -> Date {
        let lookback = now.addingTimeInterval(-crashLookback)
        guard let previous = previousLaunchStart else { return lookback }
        return max(previous, lookback)
    }

    /// "NSRangeException: index 3 beyond bounds" or "EXC_BAD_ACCESS (SIGSEGV)": the first line.
    static func recordedCrashSummary(_ data: Data) -> String? {
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let line = text.split(separator: "\n", maxSplits: 1).first, line.hasPrefix("Crash: ") else { return nil }
        let summary = line.dropFirst("Crash: ".count).trimmingCharacters(in: .whitespaces)
        return summary.isEmpty ? nil : summary
    }

    /// The stack from a record, at most `maxCrashFrames` lines.
    static func recordedCrashStack(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "\nStack:\n") else { return nil }
        var rest = text[start.upperBound...]
        if let end = rest.range(of: "\n--- ") { rest = rest[..<end.lowerBound] }
        let frames = rest.split(separator: "\n").prefix(maxCrashFrames)
        return frames.isEmpty ? nil : frames.joined(separator: "\n")
    }

    /// Call once your first screen is showing. If the app crashed since the last check (and
    /// `installCrashDetection()` recorded it), asks whether to send a report and, if so, starts
    /// one with the crash record attached.
    ///
    /// ```swift
    /// .task { await snag.offerReportAfterCrash(logFiles: [logFileURL]) }
    /// ```
    ///
    /// - Returns: true if the person chose to send a report and did not cancel its review.
    @MainActor
    @discardableResult
    public func offerReportAfterCrash(
        logFiles: [URL] = [],
        defaults: UserDefaults = .standard
    ) async -> Bool {
        guard let crash = Self.latestCrash() else { return false }
        let lastSeen = defaults.object(forKey: Self.lastCrashSeenKey) as? Date
        guard Self.isNewCrash(crash, lastSeen: lastSeen) else { return false }
        // Nothing on screen yet: ask on a later call rather than never.
        guard let presenter = Self.topViewController() else { return false }
        // Remember it either way, so the question is asked once per crash.
        defaults.set(crash.date, forKey: Self.lastCrashSeenKey)

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        let send = await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "\(appName) quit unexpectedly",
                message: "Would you like to send a report? The crash details are attached, and you can review them before sending.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in continuation.resume(returning: false) })
            let sendAction = UIAlertAction(title: "Send Report…", style: .default) { _ in continuation.resume(returning: true) }
            alert.addAction(sendAction)
            alert.preferredAction = sendAction
            presenter.present(alert, animated: true)
        }
        guard send else { return false }
        return await report(
            logFiles: logFiles, extraDiagnostics: ["crash_prompt": "yes"],
            includeWindowSnapshot: false, includeCrashReport: true
        ) != nil
    }
}
#endif
