import XCTest
import TarmacKit

final class AppVersionTests: XCTestCase {
    func testABundledAppReportsItsShortVersion() {
        XCTAssertEqual(AppVersion.resolve(bundleShortVersion: "0.13.1", env: [:]), "0.13.1")
    }

    /// A bundle's own version is what it was built as; an inherited variable
    /// must not relabel it.
    func testTheBundleVersionWinsOverTheEnvironment() {
        XCTAssertEqual(
            AppVersion.resolve(bundleShortVersion: "0.13.1", env: ["TARMAC_APP_VERSION": "9.9.9"]),
            "0.13.1"
        )
    }

    func testAnUnbundledBinaryReadsTheEnvironment() {
        XCTAssertEqual(AppVersion.resolve(bundleShortVersion: nil, env: ["TARMAC_APP_VERSION": "0.13.1"]), "0.13.1")
        XCTAssertEqual(AppVersion.resolve(bundleShortVersion: "", env: ["TARMAC_APP_VERSION": "0.13.1"]), "0.13.1")
    }

    func testWithNeitherTheAppNamesNoVersion() {
        XCTAssertNil(AppVersion.resolve(bundleShortVersion: nil, env: [:]))
        XCTAssertNil(AppVersion.resolve(bundleShortVersion: "", env: ["TARMAC_APP_VERSION": ""]))
        XCTAssertNil(AppVersion.resolve(bundleShortVersion: nil, env: ["OTHER": "1.0.0"]))
    }
}
