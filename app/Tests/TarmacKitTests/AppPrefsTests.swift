import XCTest
@testable import TarmacKit

/// 2609.0016: the app's own `app-prefs.json`. Ported from the Rust
/// `app_prefs.rs` tests; S-numbers are the spec's.
final class AppPrefsTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func scratchDirectory() throws -> String {
        let dir = NSTemporaryDirectory() + "tarmac-app-prefs-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// S24 — beside the socket, so `make run` keeps every worktree apart.
    func testThePrefsFileSitsBesideTheDaemonSocket() {
        XCTAssertEqual(AppPrefs.path(besideSocket: "/w/.dev/tarmacd.sock"), "/w/.dev/app-prefs.json")
        XCTAssertEqual(AppPrefs.path(besideSocket: "/tarmacd.sock"), "/app-prefs.json")
        XCTAssertEqual(AppPrefs.path(besideSocket: "tarmacd.sock"), "app-prefs.json")
    }

    /// S25 — every way of not saying "off" leaves the guard on.
    func testOnlyAnExplicitFalseTurnsTheGuardOff() {
        let on: [Data?] = [
            nil,
            data("not json"),
            data("{}"),
            data(#"{"warn_before_quit":"no"}"#),
            data("[false]"),
            data(#"{"warn_before_quit":true}"#),
        ]
        for contents in on {
            XCTAssertTrue(AppPrefs.warnBeforeQuit(from: contents), "contents \(String(describing: contents))")
        }
        XCTAssertFalse(AppPrefs.warnBeforeQuit(from: data(#"{"warn_before_quit":false}"#)))
        XCTAssertFalse(AppPrefs.warnBeforeQuit(from: data(#"{"warn_before_quit":false,"later":1}"#)))
    }

    /// S26 — the bytes QA reads in `.dev/app-prefs.json`, and the round trip.
    func testTheSavedBytesAreExactAndReadBack() {
        XCTAssertEqual(AppPrefs.encode(warnBeforeQuit: false), data(#"{"warn_before_quit":false}"#))
        XCTAssertEqual(AppPrefs.encode(warnBeforeQuit: true), data(#"{"warn_before_quit":true}"#))
        XCTAssertFalse(AppPrefs.warnBeforeQuit(from: AppPrefs.encode(warnBeforeQuit: false)))
        XCTAssertTrue(AppPrefs.warnBeforeQuit(from: AppPrefs.encode(warnBeforeQuit: true)))
    }

    /// A JSON number is not a boolean. `JSONSerialization` would bridge `0` to
    /// `false` and turn the guard off; serde's `as_bool` does not.
    func testANumberOrNullIsNotAnExplicitFalse() {
        for json in [#"{"warn_before_quit":0}"#, #"{"warn_before_quit":null}"#, #"{"warn_before_quit":[false]}"#] {
            XCTAssertTrue(AppPrefs.warnBeforeQuit(from: data(json)), json)
        }
    }

    /// Whatever a damaged file looks like, it reads as the guard being on.
    func testADamagedFileLeavesTheGuardOn() {
        let damaged = [
            #"{"warn_before_quit":false"#,
            #"{"warn_before_quit":false} junk"#,
            "\u{feff}" + #"{"warn_before_quit":false}"#,
            #""warn_before_quit""#,
            "false",
            "",
        ]
        for json in damaged {
            XCTAssertTrue(AppPrefs.warnBeforeQuit(from: data(json)), json)
        }
        XCTAssertTrue(AppPrefs.warnBeforeQuit(from: Data([0xFF, 0xFE, 0x00])))
        XCTAssertFalse(AppPrefs.warnBeforeQuit(from: data("  {\"warn_before_quit\" : false}\n")))
    }

    /// Anything unreadable is the same answer as an absent file.
    func testLoadingAMissingOrUnreadableFileLeavesTheGuardOn() throws {
        let dir = try scratchDirectory()
        XCTAssertTrue(AppPrefs.load(from: dir + "/app-prefs.json"))
        XCTAssertTrue(AppPrefs.load(from: dir), "a directory in the file's place cannot be read")
    }

    func testASavedToggleReadsBackFromDisk() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        try AppPrefs.save(warnBeforeQuit: false, to: path)
        XCTAssertFalse(AppPrefs.load(from: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data(#"{"warn_before_quit":false}"#))

        try AppPrefs.save(warnBeforeQuit: true, to: path)
        XCTAssertTrue(AppPrefs.load(from: path))
    }

    /// The save goes through a temp file and renames over the old one, which
    /// has to work when the file already exists: a rename that refuses to
    /// overwrite would pin the toggle at its first value forever.
    func testSavingReplacesTheFileAndLeavesNoTempBehind() throws {
        let dir = try scratchDirectory()
        let path = dir + "/app-prefs.json"
        try AppPrefs.save(warnBeforeQuit: false, to: path)
        try AppPrefs.save(warnBeforeQuit: false, to: path)
        try AppPrefs.save(warnBeforeQuit: true, to: path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["app-prefs.json"])
    }

    func testSavingIntoAMissingDirectoryThrows() throws {
        let path = try scratchDirectory() + "/missing/app-prefs.json"
        XCTAssertThrowsError(try AppPrefs.save(warnBeforeQuit: false, to: path))
    }
}
