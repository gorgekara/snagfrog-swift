import XCTest
@testable import SnagReporter

/// Answers every request with 202 and keeps what was sent.
final class RecordingProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [(url: URL, auth: String?, body: [String: Any])] = []
    nonisolated(unsafe) static var status = 202

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.requests.append((request.url!, request.value(forHTTPHeaderField: "Authorization"), body))
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ErrorTests: XCTestCase {
    func reporter() -> SnagReporter {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        return SnagReporter(appSlug: "myapp", publicKey: "snag_pk_test", baseURL: URL(string: "https://snag.test")!, session: URLSession(configuration: config))
    }

    override func setUp() {
        RecordingProtocol.requests = []
        RecordingProtocol.status = 202
    }

    func testSendsAnErrorWithTheAppKeyAndNoHomeFolder() async throws {
        let home = SnagReporter.homeFolder
        try await reporter().send(error: "Could not open \(home)/Documents/a.txt", stack: "0  MyApp  0x10  Store.load() + 4", context: ["screen": "export"])
        let sent = try XCTUnwrap(RecordingProtocol.requests.first)
        XCTAssertEqual(sent.url.absoluteString, "https://snag.test/api/v1/errors")
        XCTAssertEqual(sent.auth, "Bearer snag_pk_test")
        XCTAssertEqual(sent.body["kind"] as? String, "error")
        XCTAssertEqual(sent.body["message"] as? String, "Could not open ~/Documents/a.txt")
        XCTAssertEqual(sent.body["stack"] as? String, "0  MyApp  0x10  Store.load() + 4")
        XCTAssertEqual((sent.body["context"] as? [String: String])?["screen"], "export")
        XCTAssertNotNil(sent.body["os"])
    }

    func testBoundsTheMessageAndReportsAServerRefusal() async {
        RecordingProtocol.status = 429
        do {
            try await reporter().send(error: String(repeating: "x", count: 900), isCrash: true)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SnagError, .server(429))
        }
        XCTAssertEqual((RecordingProtocol.requests.first?.body["message"] as? String)?.count, 500)
        XCTAssertEqual(RecordingProtocol.requests.first?.body["kind"] as? String, "crash")
    }

    func testReadsTheCrashedThreadFromACrashReport() {
        let body = """
        {"procName":"MyApp","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
         "usedImages":[{"name":"MyApp"},{"name":"libswiftCore.dylib"}],
         "threads":[
          {"frames":[{"imageIndex":1,"imageOffset":16,"symbol":"idle","symbolLocation":0}]},
          {"triggered":true,"frames":[
            {"imageIndex":0,"imageOffset":6699,"symbol":"TimerEngine.resume()","symbolLocation":12},
            {"imageIndex":1,"imageOffset":255},
            {"imageIndex":9,"imageOffset":1,"symbol":"main","symbolLocation":3}]}]}
        """
        let file = #"{"app_name":"MyApp","bug_type":"309"}"# + "\n" + body
        XCTAssertEqual(SnagReporter.crashedThreadStack(Data(file.utf8)), """
        0  MyApp  0x1a2b  TimerEngine.resume() + 12
        1  libswiftCore.dylib  0xff  ???
        2  ???  0x1  main + 3
        """)
        XCTAssertNil(SnagReporter.crashedThreadStack(Data("Exception Type: EXC_CRASH\n".utf8)))
        XCTAssertNil(SnagReporter.crashedThreadStack(Data((#"{"app_name":"MyApp"}"# + "\n" + #"{"threads":[{"frames":[]}]}"#).utf8)))
    }
}
