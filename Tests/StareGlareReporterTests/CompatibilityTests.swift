import XCTest
@testable import StareGlareReporter
import SnagReporter

/// Apps written before the StareGlare rename keep building and keep their stored state.
final class CompatibilityTests: XCTestCase {
    @available(*, deprecated)
    func testOldNamesStillWork() {
        let reporter: SnagReporter = SnagReporter(
            appSlug: "hourslip", publicKey: "stareglare_pk_test",
            baseURL: URL(string: "https://stareglare.example.com")!
        )
        XCTAssertEqual(reporter.appSlug, "hourslip")
        let error: SnagError = .invalidResponse
        XCTAssertEqual(error, StareGlareError.invalidResponse)
    }

    func testStoredDateFallsBackToPreRenameKey() throws {
        let suite = "stareglare-compat-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = StareGlareReporter.lastCrashSeenKey
        XCTAssertEqual(StareGlareReporter.legacyKey(for: key), "SnagReporter.lastCrashSeen")

        XCTAssertNil(StareGlareReporter.storedDate(forKey: key, in: defaults))
        let old = Date(timeIntervalSince1970: 1_000)
        defaults.set(old, forKey: "SnagReporter.lastCrashSeen")
        XCTAssertEqual(StareGlareReporter.storedDate(forKey: key, in: defaults), old)

        let new = Date(timeIntervalSince1970: 2_000)
        defaults.set(new, forKey: key)
        XCTAssertEqual(StareGlareReporter.storedDate(forKey: key, in: defaults), new)
    }
}
