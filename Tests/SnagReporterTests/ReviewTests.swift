import XCTest
@testable import SnagReporter

/// Answers every request with a session, and remembers what was asked.
final class StubServer: URLProtocol {
    nonisolated(unsafe) static var bodies: [Data] = []

    static func session() -> URLSession {
        bodies = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.bodies.append(body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"token":"tok","url":"https://snag.example.com/r/hourslip?s=tok"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class ReviewTests: XCTestCase {
    private let log = Attachment(filename: "app.log", contentType: "text/plain", data: Data("log line".utf8))
    private let crash = Attachment(filename: "HourSlip-2026-10-03-101500.ips", contentType: "text/plain", data: Data("crash".utf8))
    private let snapshot = Attachment(filename: "window.jpg", contentType: "image/jpeg", data: Data([0xFF, 0xD8]))

    private func reporter() -> SnagReporter {
        SnagReporter(appSlug: "hourslip", publicKey: "snag_pk_test",
                     baseURL: URL(string: "https://snag.example.com")!, session: StubServer.session())
    }

    private func uploadedFilenames() throws -> [[String]] {
        try StubServer.bodies.map { body in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(json["files"] as? [[String: Any]]).compactMap { $0["filename"] as? String }
        }
    }

    @MainActor
    func testNothingIsUploadedWhenTheReviewIsCancelled() async {
        let url = await reporter().submit(diagnostics: ["os_version": "macOS 15.1"], files: [log, crash],
                                          showsProgress: false, review: { _, _ in nil })
        XCTAssertNil(url)
        XCTAssertTrue(StubServer.bodies.isEmpty, "a cancelled review must not reach the network")
    }

    @MainActor
    func testNothingIsUploadedUntilTheReviewReturns() async throws {
        var requestsSeenDuringReview = -1
        var shown: [Attachment] = []
        let url = await reporter().submit(diagnostics: [:], files: [log, crash], showsProgress: false) { _, files in
            requestsSeenDuringReview = StubServer.bodies.count
            shown = files
            return files
        }
        XCTAssertEqual(requestsSeenDuringReview, 0)
        XCTAssertEqual(shown, [log, crash], "the review shows exactly what would be uploaded")
        XCTAssertEqual(url?.absoluteString, "https://snag.example.com/r/hourslip?s=tok")
        XCTAssertEqual(try uploadedFilenames(), [["app.log", "HourSlip-2026-10-03-101500.ips"]])
    }

    @MainActor
    func testOnlyTheFilesThePersonKeptAreUploaded() async throws {
        _ = await reporter().submit(diagnostics: [:], files: [log, crash, snapshot], showsProgress: false) { _, files in
            files.filter { $0.filename == "app.log" }
        }
        XCTAssertEqual(try uploadedFilenames(), [["app.log"]])
    }

    @MainActor
    func testWithoutAReviewEverythingIsUploaded() async throws {
        _ = await reporter().submit(diagnostics: [:], files: [log, snapshot], showsProgress: false, review: nil)
        XCTAssertEqual(try uploadedFilenames(), [["app.log", "window.jpg"]])
    }

    func testFilesAreNamedInPlainWords() {
        XCTAssertEqual(SnagReporter.reviewKind(of: crash), "Crash report")
        XCTAssertEqual(SnagReporter.reviewKind(of: snapshot), "Window snapshot")
        XCTAssertEqual(SnagReporter.reviewKind(of: log), "Log")
        XCTAssertTrue(SnagReporter.reviewTitle(for: log).hasPrefix("Log · app.log ("))
    }

    func testDetailsAreReadableAndInAStableOrder() {
        XCTAssertEqual(
            SnagReporter.reviewDetails(["os_version": "macOS 15.1", "app_version": "1.4.2", "crash": "EXC_BAD_ACCESS"]),
            "App version: 1.4.2\nCrash: EXC_BAD_ACCESS\nOs version: macOS 15.1"
        )
    }

    #if canImport(AppKit)
    @MainActor
    func testReviewWindowKeepsOnlyTickedFiles() {
        _ = NSApplication.shared
        let window = SnagReviewWindow(diagnostics: ["os_version": "macOS 15.1"], files: [log, crash, snapshot],
                                      destination: URL(string: "https://snag.example.com")!)
        XCTAssertEqual(window.boxes.map(\.title).first, SnagReporter.reviewTitle(for: log))
        XCTAssertEqual(window.ticked, [log, crash, snapshot], "everything starts ticked")
        window.boxes[1].state = .off
        XCTAssertEqual(window.ticked, [log, snapshot])
    }
    #endif
}
