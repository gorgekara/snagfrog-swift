import XCTest
@testable import SnagReporter

final class SnagReporterTests: XCTestCase {
    let reporter = SnagReporter(
        appSlug: "hourslip",
        publicKey: "snag_pk_test",
        baseURL: URL(string: "https://snag.example.com")!
    )

    func testReportPageURLUsesShortKeysAndPrefixesCustomOnes() {
        let url = reporter.reportPageURL(diagnostics: [
            "app_version": "1.4.2", "os_version": "macOS 15.1.0", "gpu": "M3 Pro"
        ])
        XCTAssertEqual(
            url.absoluteString,
            "https://snag.example.com/r/hourslip?v=1.4.2&d_gpu=M3%20Pro&os=macOS%2015.1.0"
        )
    }

    func testReportPageURLWithoutDiagnosticsHasNoQuery() {
        XCTAssertEqual(reporter.reportPageURL().absoluteString, "https://snag.example.com/r/hourslip")
    }

    func testTailReadsOnlyTheEndOfAFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("snag-test-\(UUID()).log")
        try Data("0123456789".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let tail = try XCTUnwrap(SnagReporter.tail(of: file, maxBytes: 4))
        XCTAssertEqual(String(decoding: tail.data, as: UTF8.self), "6789")
        XCTAssertEqual(tail.filename, file.lastPathComponent)

        let whole = try XCTUnwrap(SnagReporter.tail(of: file, maxBytes: 100))
        XCTAssertEqual(whole.data.count, 10)
    }

    func testTailOfMissingFileIsNil() {
        XCTAssertNil(SnagReporter.tail(of: URL(fileURLWithPath: "/nonexistent/x.log"), maxBytes: 10))
    }

    func testRequestEncodesFilesAsBase64() throws {
        let body = SessionRequest(
            diagnostics: ["build": "88"],
            files: [Attachment(filename: "app.log", contentType: "text/plain", data: Data("hi".utf8))]
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        let files = try XCTUnwrap(json?["files"] as? [[String: String]])
        XCTAssertEqual(files.first?["data"], "aGk=")
        XCTAssertEqual(files.first?["contentType"], "text/plain")
        XCTAssertEqual((json?["diagnostics"] as? [String: String])?["build"], "88")
    }

    func testDefaultDiagnosticsIncludeOSAndArch() {
        let d = SnagReporter.defaultDiagnostics()
        XCTAssertTrue(d["os_version"]?.hasPrefix("macOS ") ?? false)
        XCTAssertNotNil(d["arch"])
    }

    private func blob(_ name: String, _ bytes: Int, type: String = "text/plain") -> Attachment {
        Attachment(filename: name, contentType: type, data: Data(repeating: 65, count: bytes))
    }

    func testFitForUploadKeepsSnapshotAndCapsFileCount() {
        let logs = (1...6).map { blob("log\($0).log", 100) }
        let snapshot = blob("window.jpg", 50, type: "image/jpeg")
        let fitted = SnagReporter.fitForUpload(logs: logs, snapshot: snapshot)
        XCTAssertEqual(fitted.map(\.filename), ["log1.log", "log2.log", "log3.log", "window.jpg"])
    }

    func testFitForUploadShrinksLogsToTheTotalBudget() {
        let logs = [blob("big.log", 3_000), blob("small.log", 100), blob("huge.log", 5_000)]
        let snapshot = blob("window.jpg", 1_000, type: "image/jpeg")
        let fitted = SnagReporter.fitForUpload(logs: logs, snapshot: snapshot, maxTotalBytes: 4_000)
        XCTAssertEqual(fitted.map(\.filename), ["big.log", "small.log", "huge.log", "window.jpg"])
        XCTAssertLessThanOrEqual(fitted.reduce(0) { $0 + $1.data.count }, 4_000)
        XCTAssertEqual(fitted[1].data.count, 100, "short logs are kept whole")
        XCTAssertEqual(fitted[3].data.count, 1_000, "the snapshot is never trimmed")
    }

    func testFitForUploadWithoutSnapshotUsesAllFourSlots() {
        let logs = (1...5).map { blob("log\($0).log", 10) }
        XCTAssertEqual(SnagReporter.fitForUpload(logs: logs, snapshot: nil).count, 4)
    }
}

#if canImport(AppKit)
import AppKit

final class SnagReporterUITests: XCTestCase {
    func testBundledIconLoads() {
        let icon = SnagReporter.icon
        XCTAssertGreaterThan(icon.representations.first?.pixelsWide ?? 0, 128, "icon should be the bundled high-res PNG")
        XCTAssertEqual(SnagReporter.icon(size: 16).size, NSSize(width: 16, height: 16))
    }

    @MainActor
    func testMenuItemHasIconTitleAndLiveTarget() throws {
        let reporter = SnagReporter(appSlug: "hourslip", publicKey: "k", baseURL: URL(string: "https://snag.example.com")!)
        let item = reporter.menuItem(logFiles: { [] })
        XCTAssertEqual(item.title, "Report an Issue…")
        XCTAssertEqual(item.image?.size, NSSize(width: 16, height: 16))
        XCTAssertNotNil(item.target, "target must stay alive (NSMenuItem.target is weak)")
        XCTAssertTrue(item.target?.responds(to: item.action!) ?? false)
        XCTAssertEqual(reporter.menuItem(title: "Send Feedback…").title, "Send Feedback…")
    }
}
#endif
