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
}
