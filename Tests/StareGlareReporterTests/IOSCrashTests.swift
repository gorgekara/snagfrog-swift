import XCTest
@testable import StareGlareReporter

#if os(iOS)
final class IOSCrashTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("stareglare-ios-crash-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    let record = """
    Crash: EXC_BAD_ACCESS (SIGSEGV)
    App: com.acme.app 1.4.2 (88)
    OS: iOS 18.1.0
    Model: iPhone15,2
    Binary: MyApp 0x102a4c000 uuid 6A1C2B3D-0000-4000-8000-000000000001

    Stack:
    0   MyApp                               0x0000000102a50f10 MyApp + 20240
    1   libsystem_platform.dylib            0x00000001f0e2a0a4 _sigtramp + 56
    2   MyApp                               0x0000000102a51000 MyApp + 20480

    --- Unified log ---
    2026-11-09 10:00:00.000+0100 error  [com.acme.app:sync] failed

    """

    @discardableResult
    func write(_ text: String, age: TimeInterval = 60) throws -> URL {
        let url = dir.appendingPathComponent(StareGlareReporter.crashRecordFilename)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func testReadsTheSummaryAndStackOfARecord() throws {
        try write(record)
        let crash = try XCTUnwrap(StareGlareReporter.latestCrash(in: dir, since: Date().addingTimeInterval(-3600)))
        XCTAssertEqual(crash.summary, "EXC_BAD_ACCESS (SIGSEGV)")
        let stack = try XCTUnwrap(StareGlareReporter.recordedCrashStack(Data(record.utf8)))
        XCTAssertEqual(stack.split(separator: "\n").count, 3, "the unified log is not part of the stack")
        XCTAssertTrue(stack.hasPrefix("0   MyApp"))
    }

    func testIgnoresARecordFromBeforeThePreviousSession() throws {
        try write(record, age: 7200)
        XCTAssertNil(StareGlareReporter.latestCrash(in: dir, since: Date().addingTimeInterval(-3600)))
        XCTAssertNil(StareGlareReporter.latestCrash(in: dir.appendingPathComponent("nope")))
    }

    func testARecordWithoutAHeaderHasNoSummary() {
        XCTAssertNil(StareGlareReporter.recordedCrashSummary(Data("garbage".utf8)))
        XCTAssertNil(StareGlareReporter.recordedCrashStack(Data("Crash: x\n".utf8)))
    }

    func testPreviousSessionStartIsAtMostAWeekAgo() {
        let now = Date()
        XCTAssertGreaterThanOrEqual(StareGlareReporter.previousSessionStart(now: now), now.addingTimeInterval(-StareGlareReporter.crashLookback))
    }

    func testTheHeaderNamesTheBinaryForSymbolication() {
        let header = StareGlareReporter.crashHeaderText()
        XCTAssertTrue(header.contains("OS: iOS "))
        XCTAssertTrue(header.contains("Binary: "), header)
    }

    func testTheRecordIsMarkedAsACrashInTheReport() throws {
        let url = try write(record)
        let crash = try XCTUnwrap(StareGlareReporter.latestCrash(in: dir, since: Date().addingTimeInterval(-3600)))
        let context = StareGlareReporter.crashContext(crash)
        XCTAssertEqual(context.diagnostics["crash"], "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertEqual(context.attachment?.filename, url.lastPathComponent)
        XCTAssertEqual(context.attachment.map(StareGlareReporter.reviewKind(of:)), "Crash report")
    }

    @MainActor
    func testAnUncaughtExceptionIsRecorded() throws {
        StareGlareReporter.installCrashDetection(defaults: UserDefaults(suiteName: "stareglare-ios-crash-tests")!)
        let file = StareGlareReporter.crashDirectory.appendingPathComponent(StareGlareReporter.crashRecordFilename)
        defer { try? FileManager.default.removeItem(at: file) }
        StareGlareReporter.recordException(NSException(name: .rangeException, reason: "index 3 beyond\nbounds", userInfo: nil))
        let crash = try XCTUnwrap(StareGlareReporter.latestCrash(since: Date().addingTimeInterval(-60)))
        XCTAssertEqual(crash.summary, "NSRangeException: index 3 beyond bounds")
    }

    @MainActor
    func testDeviceDiagnostics() {
        let d = StareGlareReporter.defaultDiagnostics().merging(StareGlareReporter.deviceDiagnostics()) { _, new in new }
        XCTAssertNotNil(d["device_family"])
        XCTAssertNotNil(d["free_disk_gb"])
        XCTAssertNil(d["device_name"], "the device's name is often its owner's")
    }

    func testMovesTheCrashRecordFromBeforeTheRename() throws {
        let legacy = dir.appendingPathComponent("legacy", isDirectory: true)
        let current = dir.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let old = legacy.appendingPathComponent(StareGlareReporter.crashRecordFilename)
        try Data(record.utf8).write(to: old)

        StareGlareReporter.moveLegacyCrashRecord(to: current, from: legacy)

        let crash = try XCTUnwrap(StareGlareReporter.latestCrash(in: current, since: .distantPast))
        XCTAssertEqual(crash.summary, "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
}
#endif
