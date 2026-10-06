import XCTest
import os
@testable import SnagReporter

final class UnifiedLogTests: XCTestCase {
    typealias Line = SnagReporter.LogLine
    let utc = TimeZone(secondsFromGMT: 0)!
    let noon = Date(timeIntervalSince1970: 1_791_288_000) // 2026-10-06 12:00:00 UTC

    func line(_ message: String, _ level: String = "info", subsystem: String = "com.acme.app",
              category: String = "sync", secondsAfterNoon: TimeInterval = 0) -> Line {
        Line(date: noon.addingTimeInterval(secondsAfterNoon), level: level, subsystem: subsystem, category: category, message: message)
    }

    // MARK: Which entries are the app's

    func testByDefaultTakesTheAppsOwnSubsystemsAndUnlabelledEntries() {
        let log = SnagReporter.UnifiedLog.app
        XCTAssertTrue(log.includes(subsystem: "com.acme.app", bundleID: "com.acme.app"))
        // A common convention: one subsystem per area, under the bundle identifier.
        XCTAssertTrue(log.includes(subsystem: "com.acme.app.network", bundleID: "com.acme.app"))
        // NSLog and Logger() carry no subsystem.
        XCTAssertTrue(log.includes(subsystem: "", bundleID: "com.acme.app"))
        // Frameworks log inside the app's process too; those are not the app's.
        XCTAssertFalse(log.includes(subsystem: "com.apple.AppKit", bundleID: "com.acme.app"))
        XCTAssertFalse(log.includes(subsystem: "com.acme.application", bundleID: "com.acme.app"))
        XCTAssertFalse(log.includes(subsystem: "com.other.sdk", bundleID: "com.acme.app"))
    }

    func testNamedSubsystemsReplaceTheBundleIdentifier() {
        let log = SnagReporter.UnifiedLog(subsystems: ["com.acme.core", "sync"], includesUnlabeled: false)
        XCTAssertTrue(log.includes(subsystem: "com.acme.core", bundleID: "com.acme.app"))
        XCTAssertTrue(log.includes(subsystem: "com.acme.core.db", bundleID: "com.acme.app"))
        XCTAssertTrue(log.includes(subsystem: "sync", bundleID: "com.acme.app"))
        XCTAssertFalse(log.includes(subsystem: "com.acme.app", bundleID: "com.acme.app"))
        XCTAssertFalse(log.includes(subsystem: "", bundleID: "com.acme.app"))
    }

    func testWithoutABundleIdentifierTakesEverythingThatIsNotApples() {
        // A command-line tool has no bundle identifier.
        let log = SnagReporter.UnifiedLog.app
        XCTAssertTrue(log.includes(subsystem: "com.acme.tool", bundleID: nil))
        XCTAssertFalse(log.includes(subsystem: "com.apple.network", bundleID: nil))
    }

    func testDefaultsToTheLastFifteenMinutes() {
        XCTAssertEqual(SnagReporter.UnifiedLog.app.duration, 15 * 60)
        XCTAssertEqual(SnagReporter.UnifiedLog(last: 60).duration, 60)
    }

    // MARK: The text that is attached

    func testRendersOneEntryPerLineWithTimeLevelAndSource() throws {
        let data = try XCTUnwrap(SnagReporter.renderUnifiedLog([
            line("Sync started"),
            line("Request failed: 503", "error", category: "network", secondsAfterNoon: 1.25),
            line("plain NSLog line", "notice", subsystem: "", category: "", secondsAfterNoon: 2)
        ], maxBytes: 10_000, timeZone: utc))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), """
        2026-10-06 12:00:00.000+0000 info   [com.acme.app:sync] Sync started
        2026-10-06 12:00:01.250+0000 error  [com.acme.app:network] Request failed: 503
        2026-10-06 12:00:02.000+0000 notice plain NSLog line

        """)
    }

    func testNoEntriesMeansNoAttachment() {
        XCTAssertNil(SnagReporter.renderUnifiedLog([], maxBytes: 1000, timeZone: utc))
    }

    func testKeepsTheNewestEntriesWhenOverTheLimitAndSaysHowManyWereLeftOut() throws {
        let lines = (0..<100).map { line("entry \($0)", secondsAfterNoon: TimeInterval($0)) }
        let data = try XCTUnwrap(SnagReporter.renderUnifiedLog(lines, maxBytes: 400, timeZone: utc))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertLessThanOrEqual(data.count, 400)
        XCTAssertTrue(text.hasSuffix("entry 99\n"))
        XCTAssertFalse(text.contains("entry 0\n"))
        // Whole entries only, after a first line that says what is missing.
        let rows = text.split(separator: "\n").map(String.init)
        let kept = rows.count - 1
        XCTAssertEqual(rows[0], "… \(100 - kept) earlier entries left out")
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0.hasPrefix("2026-10-06 12:0") })
    }

    func testAnEntryLongerThanTheLimitKeepsItsEnd() throws {
        let data = try XCTUnwrap(SnagReporter.renderUnifiedLog([line(String(repeating: "x", count: 5000) + "END")], maxBytes: 200, timeZone: utc))
        XCTAssertLessThanOrEqual(data.count, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("END\n"))
    }

    func testAMessageWithSeveralLinesStaysTogether() throws {
        let data = try XCTUnwrap(SnagReporter.renderUnifiedLog([line("first\nsecond")], maxBytes: 1000, timeZone: utc))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("[com.acme.app:sync] first\nsecond\n"))
    }

    func testLeavesOutEntriesThatAreNothingButHiddenValues() {
        XCTAssertTrue(SnagReporter.isFullyRedacted("<private>"))
        XCTAssertTrue(SnagReporter.isFullyRedacted("<private>, <private>"))
        XCTAssertTrue(SnagReporter.isFullyRedacted(" <private>\n"))
        XCTAssertFalse(SnagReporter.isFullyRedacted("Signed in as <private>"))
        XCTAssertFalse(SnagReporter.isFullyRedacted("Sync started"))
        XCTAssertFalse(SnagReporter.isFullyRedacted(""))
        XCTAssertFalse(SnagReporter.isFullyRedacted("..."))
    }

    // MARK: Where it goes among the files

    func testTheCrashReportComesFirstThenTheUnifiedLogThenLogFiles() {
        let file = { (name: String) in Attachment(filename: name, contentType: "text/plain", data: Data([1])) }
        let all = SnagReporter.assemble(crash: file("crash.ips"), unifiedLog: file("unified-log.log"), files: [file("a.log"), file("b.log")])
        XCTAssertEqual(all.map(\.filename), ["crash.ips", "unified-log.log", "a.log", "b.log"])
        XCTAssertEqual(SnagReporter.assemble(crash: nil, unifiedLog: nil, files: [file("a.log")]).map(\.filename), ["a.log"])
    }

    // MARK: Reading the real log of this process

    func testReadsWhatThisProcessLoggedAndNothingElse() throws {
        let subsystem = "com.snagfrog.tests.\(UUID().uuidString)"
        let marker = "marker-\(UUID().uuidString)"
        Logger(subsystem: subsystem, category: "probe").error("\(marker, privacy: .public)")
        // Nothing but a private value: macOS hands back "<private>", which is left out.
        Logger(subsystem: subsystem, category: "probe").error("\(marker)")
        Logger(subsystem: "com.snagfrog.other.\(UUID().uuidString)", category: "probe").error("not-wanted-\(marker, privacy: .public)")

        let options = SnagReporter.UnifiedLog(subsystems: [subsystem], last: 60, includesUnlabeled: false)
        // The log is written asynchronously: give it a moment.
        var found: [Line] = []
        for _ in 0..<30 {
            guard let lines = SnagReporter.unifiedLogLines(options, bundleID: nil) else {
                throw XCTSkip("The unified log cannot be read in this environment")
            }
            found = lines
            if !found.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(found.map(\.message), [marker])
        XCTAssertEqual(found.first?.level, "error")
        XCTAssertEqual(found.first?.subsystem, subsystem)
        XCTAssertEqual(found.first?.category, "probe")

        let attachment = try XCTUnwrap(SnagReporter.unifiedLogAttachment(options, bundleID: nil, maxBytes: 10_000))
        XCTAssertEqual(attachment.filename, "unified-log.log")
        XCTAssertEqual(attachment.contentType, "text/plain")
        XCTAssertTrue(String(decoding: attachment.data, as: UTF8.self).contains("[\(subsystem):probe] \(marker)"))
    }

    func testLeavesOutEntriesOlderThanTheWindow() throws {
        let subsystem = "com.snagfrog.tests.\(UUID().uuidString)"
        Logger(subsystem: subsystem, category: "probe").error("old entry")
        Thread.sleep(forTimeInterval: 1.2)
        let options = SnagReporter.UnifiedLog(subsystems: [subsystem], last: 0.5, includesUnlabeled: false)
        guard let lines = SnagReporter.unifiedLogLines(options, bundleID: nil) else {
            throw XCTSkip("The unified log cannot be read in this environment")
        }
        XCTAssertEqual(lines, [])
        XCTAssertNil(SnagReporter.unifiedLogAttachment(options, bundleID: nil, maxBytes: 10_000))
    }

    @MainActor
    func testTheMenuItemCanBeAskedToAttachTheUnifiedLog() throws {
        let reporter = SnagReporter(appSlug: "hourslip", publicKey: "snag_pk_test", baseURL: URL(string: "https://snag.example.com")!)
        let item = reporter.menuItem(unifiedLog: .app)
        let target = try XCTUnwrap(item.target as? SnagMenuTarget)
        XCTAssertEqual(target.unifiedLog, .app)
        XCTAssertNil((reporter.menuItem().target as? SnagMenuTarget)?.unifiedLog)
    }
}
