import XCTest
@testable import SnagReporter

final class CrashTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("snag-crash-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func ips(app: String, bugType: String = "309", exception: String? = #"{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"}"#) -> String {
        let body = exception.map { #"{"procName":"\#(app)","exception":\#($0)}"# } ?? #"{"procName":"\#(app)"}"#
        return #"{"app_name":"\#(app)","bug_type":"\#(bugType)","timestamp":"2026-10-03 10:00:00.00 +0200"}"# + "\n" + body
    }

    @discardableResult
    func write(_ name: String, _ text: String, age: TimeInterval = 60) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func testFindsTheNewestCrashForThisProcess() throws {
        try write("MyApp-2026-10-01-100000.ips", ips(app: "MyApp"), age: 3600)
        let newest = try write("MyApp-2026-10-03-100000.ips", ips(app: "MyApp"), age: 60)
        try write("Other-2026-10-03-110000.ips", ips(app: "Other"), age: 10)

        let crash = try XCTUnwrap(SnagReporter.latestCrash(processName: "MyApp", in: dir))
        XCTAssertEqual(crash.file.lastPathComponent, newest.lastPathComponent)
        XCTAssertEqual(crash.summary, "EXC_BAD_ACCESS (SIGSEGV)")
    }

    func testIgnoresHelpersHangsOldFilesAndOtherExtensions() throws {
        try write("MyApp-Helper-2026-10-03-100000.ips", ips(app: "MyApp-Helper"))
        try write("MyApp-2026-10-03-100001.ips", ips(app: "MyApp", bugType: "298"))
        try write("MyApp-2026-09-01-100000.ips", ips(app: "MyApp"), age: 30 * 24 * 3600)
        try write("MyApp-2026-10-03-100002.txt", ips(app: "MyApp"))
        XCTAssertNil(SnagReporter.latestCrash(processName: "MyApp", in: dir))
    }

    func testMissingDirectoryIsNil() {
        XCTAssertNil(SnagReporter.latestCrash(processName: "MyApp", in: dir.appendingPathComponent("nope")))
    }

    func testUnparseableFileStillCountsWithoutSummary() throws {
        try write("MyApp-2026-10-03-100000.ips", "not json at all")
        let crash = try XCTUnwrap(SnagReporter.latestCrash(processName: "MyApp", in: dir))
        XCTAssertNil(crash.summary)
        XCTAssertEqual(SnagReporter.crashContext(crash).diagnostics["crash"], "Crash log attached")
    }

    func testLegacyCrashTextSummary() throws {
        try write("MyApp_2026-10-03-100000_Mac.crash", "Process: MyApp [1]\nException Type:  EXC_CRASH (SIGABRT)\n")
        let crash = try XCTUnwrap(SnagReporter.latestCrash(processName: "MyApp", in: dir))
        XCTAssertEqual(crash.summary, "EXC_CRASH (SIGABRT)")
    }

    func testCrashContextAttachesTheFileAndMarksTheReport() throws {
        let url = try write("MyApp-2026-10-03-100000.ips", ips(app: "MyApp"))
        let crash = try XCTUnwrap(SnagReporter.latestCrash(processName: "MyApp", in: dir))
        let context = SnagReporter.crashContext(crash)
        XCTAssertEqual(context.attachment?.filename, url.lastPathComponent)
        XCTAssertEqual(context.attachment?.contentType, "text/plain")
        XCTAssertEqual(context.diagnostics["crash"], "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertNotNil(context.diagnostics["crash_time"])
    }

    func testIsNewCrash() {
        let now = Date()
        let crash = CrashReport(file: URL(fileURLWithPath: "/x.ips"), date: now.addingTimeInterval(-3600), summary: nil)
        XCTAssertTrue(SnagReporter.isNewCrash(crash, lastSeen: nil, now: now))
        XCTAssertTrue(SnagReporter.isNewCrash(crash, lastSeen: now.addingTimeInterval(-7200), now: now))
        XCTAssertFalse(SnagReporter.isNewCrash(crash, lastSeen: crash.date, now: now))
        let old = CrashReport(file: crash.file, date: now.addingTimeInterval(-3 * 24 * 3600), summary: nil)
        XCTAssertFalse(SnagReporter.isNewCrash(old, lastSeen: nil, now: now))
    }
}
