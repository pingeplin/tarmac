import XCTest
@testable import TarmacKit

/// The app's own `app-prefs.json`. The first part is spec 2609.0016's, ported
/// from the Rust `app_prefs.rs` tests; the part under the 2610.0005 mark is
/// that spec's. S-numbers are those of the part's own spec.
final class AppPrefsTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func scratchDirectory() throws -> String {
        let dir = NSTemporaryDirectory() + "tarmac-app-prefs-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// S24 — the place of release 0.16.0 and older, beside the socket, which
    /// `migrate` reads. It kept `make run` worktrees apart.
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

    /// S26 — the bytes QA reads in `.dev/config/app-prefs.json`, and the round trip.
    func testTheSavedBytesAreExactAndReadBack() {
        let off = AppPrefs.Values(warnBeforeQuit: false), on = AppPrefs.Values(warnBeforeQuit: true)
        XCTAssertEqual(AppPrefs.encode(off), data(#"{"warn_before_quit":false}"#))
        XCTAssertEqual(AppPrefs.encode(on), data(#"{"warn_before_quit":true}"#))
        XCTAssertFalse(AppPrefs.warnBeforeQuit(from: AppPrefs.encode(off)))
        XCTAssertTrue(AppPrefs.warnBeforeQuit(from: AppPrefs.encode(on)))
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
        XCTAssertTrue(AppPrefs.load(from: dir + "/app-prefs.json").warnBeforeQuit)
        XCTAssertTrue(AppPrefs.load(from: dir).warnBeforeQuit, "a directory in the file's place cannot be read")
    }

    func testASavedToggleReadsBackFromDisk() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        try AppPrefs.save(AppPrefs.Values(warnBeforeQuit: false), to: path)
        XCTAssertFalse(AppPrefs.load(from: path).warnBeforeQuit)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data(#"{"warn_before_quit":false}"#))

        try AppPrefs.save(AppPrefs.Values(warnBeforeQuit: true), to: path)
        XCTAssertTrue(AppPrefs.load(from: path).warnBeforeQuit)
    }

    /// The save goes through a temp file and renames over the old one, which
    /// has to work when the file already exists: a rename that refuses to
    /// overwrite would pin the toggle at its first value forever.
    func testSavingReplacesTheFileAndLeavesNoTempBehind() throws {
        let dir = try scratchDirectory()
        let path = dir + "/app-prefs.json"
        try AppPrefs.save(AppPrefs.Values(warnBeforeQuit: false), to: path)
        try AppPrefs.save(AppPrefs.Values(warnBeforeQuit: false), to: path)
        try AppPrefs.save(AppPrefs.Values(warnBeforeQuit: true), to: path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["app-prefs.json"])
    }

    func testSavingIntoAMissingDirectoryMakesIt() throws {
        let dir = try scratchDirectory()
        let path = dir + "/missing/deep/app-prefs.json"
        try AppPrefs.save(AppPrefs.Values(warnBeforeQuit: false), to: path)
        XCTAssertFalse(AppPrefs.load(from: path).warnBeforeQuit)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir + "/missing/deep"), ["app-prefs.json"])
    }

    func testSavingUnderARegularFileThrows() throws {
        let dir = try scratchDirectory()
        try data("x").write(to: URL(fileURLWithPath: dir + "/blocker"))
        let path = dir + "/blocker/app-prefs.json"
        XCTAssertThrowsError(try AppPrefs.save(AppPrefs.Values(warnBeforeQuit: false), to: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: issue #220 — the file is in the config directory

    func testThePrefsFileSitsInTheConfigDirectory() {
        XCTAssertEqual(AppPrefs.path(configDir: "/w/.dev/config"), "/w/.dev/config/app-prefs.json")
        XCTAssertEqual(AppPrefs.path(configDir: "/w/.dev/config/"), "/w/.dev/config/app-prefs.json")
        XCTAssertEqual(AppPrefs.path(configDir: "/"), "/app-prefs.json")
    }

    /// A scratch launch pins the socket and not the config directory. Its
    /// config directory is then the installed app's, so its file stays beside
    /// the socket. An empty value pins nothing.
    func testAPinnedSocketWithNoPinnedConfigDirectoryKeepsTheFileBesideIt() {
        typealias Case = (configOverride: String?, socketOverride: String?, expected: String)
        let cases: [Case] = [
            (nil, nil, "/c/tarmac/app-prefs.json"),
            ("/c/tarmac", "/s/tarmacd.sock", "/c/tarmac/app-prefs.json"),
            ("/c/tarmac", nil, "/c/tarmac/app-prefs.json"),
            (nil, "/s/tarmacd.sock", "/s/app-prefs.json"),
            ("", "/s/tarmacd.sock", "/s/app-prefs.json"),
            (nil, "", "/c/tarmac/app-prefs.json"),
            ("", "", "/c/tarmac/app-prefs.json"),
        ]
        for c in cases {
            XCTAssertEqual(
                AppPrefs.path(
                    configDir: "/c/tarmac", configOverride: c.configOverride, socket: "/s/tarmacd.sock",
                    socketOverride: c.socketOverride
                ),
                c.expected,
                "configOverride: \(c.configOverride ?? "nil"), socketOverride: \(c.socketOverride ?? "nil")"
            )
        }
    }

    func testMigrationCopiesTheBytesOfTheOldFile() throws {
        let dir = try scratchDirectory()
        let legacy = dir + "/old/app-prefs.json"
        let path = dir + "/config/deep/app-prefs.json"
        let bytes = data(#"{"warn_before_quit":false,"a_later_key":[1,2]}"# + "\n")
        try FileManager.default.createDirectory(atPath: dir + "/old", withIntermediateDirectories: true)
        try bytes.write(to: URL(fileURLWithPath: legacy))
        let before = try FileManager.default.attributesOfItem(atPath: legacy)

        try AppPrefs.migrate(from: legacy, to: path)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: legacy)), bytes)
        let copy = try FileManager.default.attributesOfItem(atPath: path)
        let old = try FileManager.default.attributesOfItem(atPath: legacy)
        XCTAssertEqual(copy[.type] as? FileAttributeType, .typeRegular)
        XCTAssertNotEqual(copy[.systemFileNumber] as? Int, old[.systemFileNumber] as? Int)
        XCTAssertEqual(old[.systemFileNumber] as? Int, before[.systemFileNumber] as? Int)
        XCTAssertEqual(old[.modificationDate] as? Date, before[.modificationDate] as? Date)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir + "/config/deep"), ["app-prefs.json"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir + "/old"), ["app-prefs.json"])
    }

    func testTheFileInTheConfigDirectoryWinsOverTheOldOne() throws {
        let dir = try scratchDirectory()
        let legacy = dir + "/old/app-prefs.json", path = dir + "/config/app-prefs.json"
        try FileManager.default.createDirectory(atPath: dir + "/old", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/config", withIntermediateDirectories: true)
        let oldBytes = data(#"{"warn_before_quit":false}"#), newBytes = data(#"{"warn_before_quit":true}"#)
        try newBytes.write(to: URL(fileURLWithPath: path))
        try oldBytes.write(to: URL(fileURLWithPath: legacy))

        try AppPrefs.migrate(from: legacy, to: path)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), newBytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: legacy)), oldBytes)
    }

    func testWithNoFileNothingIsMade() throws {
        let dir = try scratchDirectory()
        let path = dir + "/config/app-prefs.json"
        try AppPrefs.migrate(from: dir + "/old/app-prefs.json", to: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/config"))
    }

    func testAnUnreadableOldFileMakesNothing() throws {
        let dir = try scratchDirectory()
        let legacy = dir + "/old/app-prefs.json"
        let path = dir + "/config/app-prefs.json"
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AppPrefs.migrate(from: legacy, to: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/config"))
    }

    // MARK: 2610.0005 — the font choices share the file

    private typealias Values = AppPrefs.Values

    /// S1 — the roles are written after the guard, in a fixed order.
    func testTheFontChoicesAreWrittenAfterTheGuardInRoleOrder() {
        let values = Values(warnBeforeQuit: false, fonts: [.document: "Helvetica Neue", .terminal: "Menlo"])
        XCTAssertEqual(
            AppPrefs.encode(values),
            data(#"{"warn_before_quit":false,"terminal_font":"Menlo","document_font":"Helvetica Neue"}"#)
        )
        let all = Values(fonts: [.interface: "Monaco", .document: "Georgia", .terminal: "Menlo"])
        XCTAssertEqual(
            AppPrefs.encode(all),
            data(#"{"warn_before_quit":true,"terminal_font":"Menlo","interface_font":"Monaco","document_font":"Georgia"}"#)
        )
    }

    /// S3
    func testAFontKeyReadsAsThatRolesChoice() {
        let values = AppPrefs.decode(data(#"{"warn_before_quit":false,"interface_font":"Monaco"}"#))
        XCTAssertEqual(values, Values(warnBeforeQuit: false, fonts: [.interface: "Monaco"]))
    }

    /// S4
    func testSavedFontChoicesReadBackFromDisk() throws {
        let dir = try scratchDirectory()
        let path = dir + "/app-prefs.json"
        let values = Values(warnBeforeQuit: false, fonts: [.terminal: "Menlo", .interface: "Monaco", .document: "Georgia"])
        try AppPrefs.save(values, to: path)
        XCTAssertEqual(AppPrefs.load(from: path), values)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["app-prefs.json"])
    }

    /// S5 — one preference saved must not drop another.
    func testChangingOnePreferenceKeepsTheOthers() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        try data(#"{"warn_before_quit":true,"terminal_font":"Menlo"}"#).write(to: URL(fileURLWithPath: path))

        var values = AppPrefs.load(from: path)
        values.warnBeforeQuit = false
        try AppPrefs.save(values, to: path)
        XCTAssertEqual(AppPrefs.load(from: path), Values(warnBeforeQuit: false, fonts: [.terminal: "Menlo"]))

        values = AppPrefs.load(from: path)
        values.fonts[.document] = "Georgia"
        try AppPrefs.save(values, to: path)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path)),
            data(#"{"warn_before_quit":false,"terminal_font":"Menlo","document_font":"Georgia"}"#)
        )
    }

    /// S20 — each key is read on its own.
    func testAKeyOfTheWrongTypeDoesNotChangeHowTheOthersRead() {
        XCTAssertEqual(
            AppPrefs.decode(data(#"{"warn_before_quit":false,"terminal_font":7,"interface_font":"Monaco"}"#)),
            Values(warnBeforeQuit: false, fonts: [.interface: "Monaco"])
        )
        XCTAssertEqual(
            AppPrefs.decode(data(#"{"warn_before_quit":"no","terminal_font":"Menlo"}"#)),
            Values(warnBeforeQuit: true, fonts: [.terminal: "Menlo"])
        )
    }

    /// S21 — the files are valid JSON, so it is the key's own rule that drops
    /// the value.
    func testAFontValueThatIsNotAUsableNameIsNoChoice() {
        let unusable = [#""""#, "null", #"["Menlo"]"#, #""a\nb""#, #""a\u001fb""#, "\"a\u{7f}b\""]
        for value in unusable {
            let file = data(#"{"warn_before_quit":false,"terminal_font":"# + value + #","interface_font":"Monaco"}"#)
            XCTAssertTrue(StrictJSON.isValid(file), value)
            XCTAssertEqual(AppPrefs.decode(file), Values(warnBeforeQuit: false, fonts: [.interface: "Monaco"]), value)
        }
    }

    /// S22
    func testAwkwardFamilyNamesSurviveTheRoundTrip() {
        for name in [#"He said "hi""#, #"back\slash"#, "蘋方-繁"] {
            let values = Values(warnBeforeQuit: false, fonts: [.terminal: name, .document: name])
            let bytes = AppPrefs.encode(values)
            XCTAssertTrue(StrictJSON.isValid(bytes), name)
            XCTAssertEqual(AppPrefs.decode(bytes), values, name)
        }
        XCTAssertEqual(
            AppPrefs.encode(Values(fonts: [.terminal: #"a"b\c"#])),
            data(#"{"warn_before_quit":true,"terminal_font":"a\"b\\c"}"#)
        )
    }

    /// S38 — a damaged file gives up its font choices with its guard.
    func testADamagedFileReadsAsAllDefaults() {
        let whole = #"{"warn_before_quit":false,"terminal_font":"Menlo"}"#
        XCTAssertEqual(AppPrefs.decode(data(whole)), Values(warnBeforeQuit: false, fonts: [.terminal: "Menlo"]))
        let damaged: [String?] = [nil, "", "[]", String(whole.dropLast()), String(whole.dropLast()) + ",}"]
        for contents in damaged {
            XCTAssertEqual(AppPrefs.decode(contents.map(data)), Values(), contents ?? "no file")
        }
    }

    /// S49 — a name the reader would refuse is never written, so it cannot
    /// damage the file and turn the guard back on.
    func testANameTheReaderRefusesIsNotWritten() {
        let values = Values(fonts: [.terminal: "", .interface: "a\nb", .document: "Georgia"])
        let bytes = AppPrefs.encode(values)
        XCTAssertEqual(bytes, data(#"{"warn_before_quit":true,"document_font":"Georgia"}"#))
        XCTAssertTrue(StrictJSON.isValid(bytes))

        // U+001F is the last character JSON forbids raw in a string; U+0020 is a space.
        for refused in ["a\u{1f}b", "a\u{7f}b"] {
            let bytes = AppPrefs.encode(Values(fonts: [.terminal: refused]))
            XCTAssertEqual(bytes, data(#"{"warn_before_quit":true}"#), refused.debugDescription)
        }
        let spaced = AppPrefs.encode(Values(fonts: [.terminal: "a b"]))
        XCTAssertEqual(spaced, data(#"{"warn_before_quit":true,"terminal_font":"a b"}"#))
    }

    // MARK: 2610.0006 — a size beside the Terminal and the Document family

    /// S4 — every family is written before every size.
    func testTheSizesAreWrittenAfterTheFamiliesInRoleOrder() {
        let values = Values(
            warnBeforeQuit: false, fonts: [.terminal: "Menlo", .document: "Georgia"],
            fontSizes: [.document: 18, .terminal: 13.5]
        )
        XCTAssertEqual(
            AppPrefs.encode(values),
            data(
                #"{"warn_before_quit":false,"terminal_font":"Menlo","document_font":"Georgia","#
                    + #""terminal_font_size":13.5,"document_font_size":18}"#
            )
        )
    }

    /// S5
    func testWithNoSizeTheBytesAreThoseOfBefore() {
        XCTAssertEqual(AppPrefs.encode(Values(fontSizes: [:])), data(#"{"warn_before_quit":true}"#))
        XCTAssertEqual(
            AppPrefs.encode(Values(fonts: [.terminal: "Menlo"], fontSizes: [:])),
            data(#"{"warn_before_quit":true,"terminal_font":"Menlo"}"#)
        )
    }

    /// A size equal to the role's standard is a choice the user made: it is
    /// written like any other, and reads back.
    func testASizeEqualToTheStandardIsWritten() {
        let values = Values(fontSizes: [.terminal: 16, .document: 14])
        XCTAssertEqual(
            AppPrefs.encode(values),
            data(#"{"warn_before_quit":true,"terminal_font_size":16,"document_font_size":14}"#)
        )
        XCTAssertEqual(AppPrefs.decode(AppPrefs.encode(values)), values)
    }

    /// S6 — one number, however the file spells it.
    func testASizeKeyReadsAsThatRolesSize() {
        XCTAssertEqual(
            AppPrefs.decode(data(#"{"warn_before_quit":false,"terminal_font_size":13.5,"document_font_size":18}"#)),
            Values(warnBeforeQuit: false, fontSizes: [.terminal: 13.5, .document: 18])
        )
        for spelling in ["16.0", "1.6e1"] {
            XCTAssertEqual(
                AppPrefs.decode(data(#"{"terminal_font_size":"# + spelling + "}")).fontSizes, [.terminal: 16], spelling
            )
        }
    }

    /// S7
    func testSavedSizesReadBackFromDisk() throws {
        let dir = try scratchDirectory()
        let path = dir + "/app-prefs.json"
        let values = Values(
            warnBeforeQuit: false, fonts: [.terminal: "Menlo", .interface: "Monaco", .document: "Georgia"],
            fontSizes: [.terminal: 20, .document: 11.5]
        )
        try AppPrefs.save(values, to: path)
        XCTAssertEqual(AppPrefs.load(from: path), values)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["app-prefs.json"])
    }

    /// S8 — a role's family and its size are two choices, and the guard a third.
    func testTheFamilyTheSizeAndTheGuardAreSavedApart() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        let saved = Values(warnBeforeQuit: false, fonts: [.terminal: "Menlo"], fontSizes: [.terminal: 20])
        let changes: [(String, (inout Values) -> Void, Values)] = [
            ("family", { $0.fonts[.terminal] = nil }, Values(warnBeforeQuit: false, fontSizes: [.terminal: 20])),
            (
                "size", { $0.fontSizes[.terminal] = 13.5 },
                Values(warnBeforeQuit: false, fonts: [.terminal: "Menlo"], fontSizes: [.terminal: 13.5])
            ),
            ("guard", { $0.warnBeforeQuit = true }, Values(fonts: [.terminal: "Menlo"], fontSizes: [.terminal: 20])),
        ]
        for (name, change, expected) in changes {
            try AppPrefs.save(saved, to: path)
            var values = AppPrefs.load(from: path)
            change(&values)
            try AppPrefs.save(values, to: path)
            XCTAssertEqual(AppPrefs.load(from: path), expected, name)
        }
    }

    private func file(terminalSize value: String) -> Data {
        data(
            #"{"warn_before_quit":false,"terminal_font_size":"# + value
                + #","document_font_size":18,"terminal_font":"Menlo"}"#
        )
    }

    private let withoutATerminalSize = Values(
        warnBeforeQuit: false, fonts: [.terminal: "Menlo"], fontSizes: [.document: 18]
    )

    /// S23 — the files are valid JSON, so it is the key's own rule that drops
    /// the value. A lenient reader takes `true` for 1.
    func testASizeThatIsNotANumberIsNoSize() {
        for value in ["true", #""16""#, "null", "[16]", "{}"] {
            let file = file(terminalSize: value)
            XCTAssertTrue(StrictJSON.isValid(file), value)
            XCTAssertEqual(AppPrefs.decode(file), withoutATerminalSize, value)
        }
    }

    /// S24 — a number the app could not have written is not moved into the
    /// range: it is not used.
    func testASizeOutOfItsRolesRangeOrOffTheStepIsNoSize() {
        for value in ["7.5", "32.5", "0", "-16", "1e9", "16.25", "13.3"] {
            let file = file(terminalSize: value)
            XCTAssertTrue(StrictJSON.isValid(file), value)
            XCTAssertEqual(AppPrefs.decode(file), withoutATerminalSize, value)
        }
        XCTAssertEqual(AppPrefs.decode(file(terminalSize: "8")).fontSizes, [.terminal: 8, .document: 18])
        XCTAssertEqual(AppPrefs.decode(file(terminalSize: "32")).fontSizes, [.terminal: 32, .document: 18])
        XCTAssertEqual(
            AppPrefs.decode(data(#"{"terminal_font_size":28,"document_font_size":28}"#)).fontSizes, [.terminal: 28]
        )
    }

    /// S25 — Interface has no size, and a size the reader would refuse is
    /// never written.
    func testASizeTheReaderRefusesIsNotWritten() {
        XCTAssertEqual(AppPrefs.decode(data(#"{"interface_font_size":12}"#)).fontSizes, [:])
        let refused: [[FontRole: Double]] = [
            [.interface: 12, .terminal: 64, .document: 13.3], [.terminal: .infinity, .document: .nan],
        ]
        for sizes in refused {
            let bytes = AppPrefs.encode(Values(fontSizes: sizes))
            XCTAssertEqual(bytes, data(#"{"warn_before_quit":true}"#), "\(sizes)")
            XCTAssertTrue(StrictJSON.isValid(bytes))
        }
    }

    /// S36 — a damaged file gives up its sizes with its guard.
    func testADamagedFileHasNoSize() {
        let whole = #"{"warn_before_quit":false,"terminal_font_size":20}"#
        XCTAssertEqual(AppPrefs.decode(data(whole)), Values(warnBeforeQuit: false, fontSizes: [.terminal: 20]))
        let damaged = [
            String(whole.dropLast()), String(whole.dropLast()) + ",}",
            #"{"warn_before_quit":false,"terminal_font_size":1e400}"#,
        ]
        for contents in damaged { XCTAssertEqual(AppPrefs.decode(data(contents)), Values(), contents) }
    }

    // MARK: 2610.0007 — the theme shares the file

    /// S3 — the theme is the last member, after every size.
    func testTheThemeIsWrittenLast() {
        XCTAssertEqual(
            AppPrefs.encode(Values(warnBeforeQuit: false, fonts: [.terminal: "Menlo"], theme: .auto)),
            data(#"{"warn_before_quit":false,"terminal_font":"Menlo","theme":"auto"}"#)
        )
        XCTAssertEqual(AppPrefs.encode(Values(theme: .light)), data(#"{"warn_before_quit":true,"theme":"light"}"#))
        XCTAssertEqual(
            AppPrefs.encode(
                Values(fonts: [.terminal: "Menlo"], fontSizes: [.terminal: 13.5, .document: 18], theme: .light)
            ),
            data(
                #"{"warn_before_quit":true,"terminal_font":"Menlo","terminal_font_size":13.5,"#
                    + #""document_font_size":18,"theme":"light"}"#
            )
        )
    }

    /// S4 — so the bytes of every file that exists today do not change.
    func testTheDarkThemeIsNotWritten() {
        XCTAssertEqual(AppPrefs.encode(Values(theme: .dark)), data(#"{"warn_before_quit":true}"#))
    }

    /// S5
    func testAThemeKeyReadsAsThatChoice() {
        XCTAssertEqual(AppPrefs.decode(data(#"{"warn_before_quit":true,"theme":"light"}"#)).theme, .light)
        XCTAssertEqual(AppPrefs.decode(data(#"{"warn_before_quit":true,"theme":"auto"}"#)).theme, .auto)
        XCTAssertEqual(AppPrefs.decode(data(#"{"warn_before_quit":true,"theme":"dark"}"#)).theme, .dark)
    }

    /// S6
    func testASavedThemeReadsBackFromDisk() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        let values = Values(fonts: [.terminal: "Menlo"], fontSizes: [.terminal: 20], theme: .light)

        try AppPrefs.save(values, to: path)

        XCTAssertEqual(AppPrefs.load(from: path), values)
        XCTAssertEqual(AppPrefs.load(from: path).theme, .light)
    }

    /// S6
    func testEveryChoiceSurvivesTheRoundTrip() {
        for choice in [ThemeChoice.auto, .light, .dark] {
            let values = Values(warnBeforeQuit: false, fonts: [.document: "Georgia"], theme: choice)
            XCTAssertEqual(AppPrefs.decode(AppPrefs.encode(values)), values, choice.rawValue)
            XCTAssertEqual(AppPrefs.decode(AppPrefs.encode(values)).theme, choice, choice.rawValue)
        }
    }

    /// S7 — another preference saved must not drop the theme.
    func testChangingTheGuardKeepsTheTheme() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        try data(#"{"warn_before_quit":true,"theme":"light"}"#).write(to: URL(fileURLWithPath: path))

        var values = AppPrefs.load(from: path)
        values.warnBeforeQuit = false
        try AppPrefs.save(values, to: path)

        XCTAssertEqual(AppPrefs.load(from: path), Values(warnBeforeQuit: false, theme: .light))
    }

    /// S7 — and the theme saved must not drop another preference.
    func testChangingTheThemeKeepsTheGuardAFontAndASize() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        try data(#"{"warn_before_quit":false,"terminal_font":"Menlo","terminal_font_size":20}"#)
            .write(to: URL(fileURLWithPath: path))

        var values = AppPrefs.load(from: path)
        values.theme = .auto
        try AppPrefs.save(values, to: path)

        XCTAssertEqual(
            AppPrefs.load(from: path),
            Values(warnBeforeQuit: false, fonts: [.terminal: "Menlo"], fontSizes: [.terminal: 20], theme: .auto)
        )
    }

    private func file(theme value: String) -> Data {
        data(#"{"warn_before_quit":false,"terminal_font":"Menlo","theme":"# + value + "}")
    }

    /// S40 — the files are valid JSON and hold the theme where `"light"`
    /// reads as one, so it is the key's own rule that drops the value. The
    /// raw values are compared exactly.
    func testAThemeThatIsNotOneOfTheThreeIsTheDarkOne() {
        let withoutATheme = Values(warnBeforeQuit: false, fonts: [.terminal: "Menlo"])
        XCTAssertEqual(
            AppPrefs.decode(file(theme: #""light""#)),
            Values(warnBeforeQuit: false, fonts: [.terminal: "Menlo"], theme: .light)
        )

        for value in [#""sepia""#, #""Light""#, #""""#, "3", "true", "null", #"["light"]"#] {
            let file = file(theme: value)
            XCTAssertTrue(StrictJSON.isValid(file), value)
            XCTAssertEqual(AppPrefs.decode(file), withoutATheme, value)
            XCTAssertEqual(AppPrefs.decode(file).theme, .dark, value)
        }
    }

    /// S41 — a bad key beside the theme does not change the theme.
    func testTheThemeIsReadBesideKeysOfTheWrongType() {
        let values = AppPrefs.decode(data(#"{"warn_before_quit":"yes","terminal_font":7,"theme":"light"}"#))

        XCTAssertEqual(values.theme, .light)
        XCTAssertTrue(values.warnBeforeQuit)
        XCTAssertNil(values.fonts[.terminal])
    }

    /// S54 — a damaged file gives up its theme with its guard. Whole, the file
    /// reads as light with the guard off, so a lenient parser fails here.
    func testADamagedFileHasTheDarkTheme() {
        let whole = #"{"warn_before_quit":false,"theme":"light"}"#
        XCTAssertEqual(AppPrefs.decode(data(whole)), Values(warnBeforeQuit: false, theme: .light))

        let damaged = AppPrefs.decode(data(String(whole.dropLast())))

        XCTAssertEqual(damaged, Values())
        XCTAssertEqual(damaged.theme, .dark)
        XCTAssertTrue(damaged.warnBeforeQuit)
    }

    // MARK: 2610.0008 — the theme of each appearance shares the file

    /// S20 — after the appearance, light first.
    func testTheThemesAreWrittenAfterTheAppearanceLightFirst() {
        XCTAssertEqual(
            AppPrefs.encode(Values(theme: .auto, themes: [.light: "solarized-light", .dark: "catppuccin-mocha"])),
            data(
                #"{"warn_before_quit":true,"theme":"auto","theme_light":"solarized-light","#
                    + #""theme_dark":"catppuccin-mocha"}"#
            )
        )
        XCTAssertEqual(
            AppPrefs.encode(
                Values(fonts: [.terminal: "Menlo"], fontSizes: [.document: 18], themes: [.dark: "github-dark"])
            ),
            data(
                #"{"warn_before_quit":true,"terminal_font":"Menlo","document_font_size":18,"#
                    + #""theme_dark":"github-dark"}"#
            )
        )
    }

    /// S20 — a dark theme for the light appearance, and one theme for both.
    func testOneDarkThemeIsWrittenForBothAppearances() {
        XCTAssertEqual(
            AppPrefs.encode(Values(theme: .light, themes: [.light: "catppuccin-mocha", .dark: "catppuccin-mocha"])),
            data(
                #"{"warn_before_quit":true,"theme":"light","theme_light":"catppuccin-mocha","#
                    + #""theme_dark":"catppuccin-mocha"}"#
            )
        )
    }

    /// S21 — so the bytes of every file that exists today do not change.
    func testTheStandardThemesAreNotWritten() {
        XCTAssertEqual(
            AppPrefs.encode(Values(themes: [.light: "breeze-light", .dark: "breeze-dark"])),
            data(#"{"warn_before_quit":true}"#)
        )
    }

    /// S21 — a Breeze id is left out only where it is the standard theme of
    /// that key's appearance.
    func testABreezeThemeIsWrittenForTheOtherAppearance() {
        XCTAssertEqual(
            AppPrefs.encode(Values(themes: [.light: "breeze-dark", .dark: "breeze-light"])),
            data(#"{"warn_before_quit":true,"theme_light":"breeze-dark","theme_dark":"breeze-light"}"#)
        )
    }

    /// 2610.0009 S31 — an id is resolved when it is used, so one that no
    /// theme has is written as it is.
    func testAnIdNoThemeHasIsWritten() {
        XCTAssertEqual(
            AppPrefs.encode(Values(themes: [.light: "sepia", .dark: "file:Gone"])),
            data(#"{"warn_before_quit":true,"theme_light":"sepia","theme_dark":"file:Gone"}"#)
        )
    }

    /// 2610.0009 S31 — a file's name can hold a quote and a backslash.
    func testAThemeIdIsWrittenAsAJSONString() {
        let values = Values(themes: [.dark: #"file:a"b\c"#])

        let bytes = AppPrefs.encode(values)

        XCTAssertEqual(bytes, data(#"{"warn_before_quit":true,"theme_dark":"file:a\"b\\c"}"#))
        XCTAssertTrue(StrictJSON.isValid(bytes))
        XCTAssertEqual(AppPrefs.decode(bytes), values)
    }

    /// 2610.0009 S31
    func testAThemeIdThatIsNotASCIISurvivesTheRoundTrip() {
        let values = Values(themes: [.light: "file:日本"])

        XCTAssertEqual(AppPrefs.decode(AppPrefs.encode(values)), values)
    }

    /// 2610.0009 S32 — a save keeps an id that no theme has.
    func testAnIdNoThemeHasSurvivesASave() {
        let bytes = data(#"{"warn_before_quit":true,"theme_dark":"file:Gone"}"#)

        XCTAssertEqual(AppPrefs.encode(AppPrefs.decode(bytes)), bytes)
    }

    /// S23
    func testAThemeKeyReadsAsTheThemeOfItsAppearance() {
        let file = #"{"warn_before_quit":false,"theme":"auto","theme_light":"github-light","#
            + #""theme_dark":"solarized-dark"}"#

        XCTAssertEqual(
            AppPrefs.decode(data(file)),
            Values(warnBeforeQuit: false, theme: .auto, themes: [.light: "github-light", .dark: "solarized-dark"])
        )
    }

    private func fileWithALightTheme(_ value: String) -> Data {
        data(
            #"{"warn_before_quit":true,"terminal_font":"Menlo","theme":"light","theme_light":"#
                + value + #","theme_dark":"github-dark"}"#
        )
    }

    /// 2610.0009 S32 — any well-formed id is an entry, whether a theme has
    /// it or not.
    func testAnyWellFormedIdIsTheThemeOfTheLightAppearance() {
        for id in ["sepia", "GitHub-Light", "file:Gone", "catppuccin-mocha"] {
            XCTAssertEqual(
                AppPrefs.decode(fileWithALightTheme("\"\(id)\"")).themes, [.light: id, .dark: "github-dark"], id
            )
        }
    }

    /// S24, and 2610.0009 S32 — the files are valid JSON, so it is the key's
    /// own rule that drops the value.
    func testAValueThatIsNoIdOrTheStandardOneGivesNoEntry() {
        let withoutALightTheme = Values(fonts: [.terminal: "Menlo"], theme: .light, themes: [.dark: "github-dark"])

        for value in [#""breeze-light""#, #""""#, "7", "null", #"["github-light"]"#] {
            let file = fileWithALightTheme(value)
            XCTAssertTrue(StrictJSON.isValid(file), value)
            XCTAssertEqual(AppPrefs.decode(file), withoutALightTheme, value)
        }
    }

    /// S24 — a dark theme, the standard theme of the dark appearance, and the
    /// theme the dark appearance has too.
    func testAThemeOfTheOtherVariantReadsAsTheThemeOfTheLightAppearance() {
        for id in ["catppuccin-mocha", "breeze-dark", "github-dark"] {
            XCTAssertEqual(
                AppPrefs.decode(fileWithALightTheme(#""\#(id)""#)),
                Values(fonts: [.terminal: "Menlo"], theme: .light, themes: [.light: id, .dark: "github-dark"]),
                id
            )
        }
    }

    /// S24
    func testBreezeLightReadsAsTheThemeOfTheDarkAppearance() {
        XCTAssertEqual(
            AppPrefs.decode(data(#"{"warn_before_quit":true,"theme_dark":"breeze-light"}"#)).themes,
            [.dark: "breeze-light"]
        )
    }

    /// S24 — bad keys beside a theme do not change the theme.
    func testAThemeIsReadBesideKeysOfTheWrongType() {
        let values = AppPrefs.decode(
            data(#"{"warn_before_quit":"yes","theme":"sepia","theme_light":"github-light","theme_dark":7}"#)
        )

        XCTAssertEqual(values.themes, [.light: "github-light"])
        XCTAssertEqual(values.theme, .dark)
        XCTAssertTrue(values.warnBeforeQuit)
    }

    /// S25 — each choice, with none or one of the seven other themes for each
    /// appearance: 3 × 8 × 8.
    func testEveryChoiceOfThemesSurvivesTheRoundTrip() {
        func themes(for variant: ThemeVariant) -> [String?] {
            [nil] + ThemeCatalog.all.map(\.id).filter { $0 != ThemeCatalog.standard(for: variant).id }
        }
        var count = 0
        for choice in ThemeChoice.allCases {
            for light in themes(for: .light) {
                for dark in themes(for: .dark) {
                    var values = Values(warnBeforeQuit: false, theme: choice)
                    values.themes[.light] = light
                    values.themes[.dark] = dark
                    XCTAssertEqual(
                        AppPrefs.decode(AppPrefs.encode(values)), values,
                        "\(choice.rawValue) \(light ?? "-") \(dark ?? "-")"
                    )
                    count += 1
                }
            }
        }
        XCTAssertEqual(count, 192)
    }

    /// S25
    func testSavedThemesReadBackFromDisk() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        let values = Values(
            fonts: [.terminal: "Menlo"], fontSizes: [.terminal: 20], theme: .light,
            themes: [.light: "catppuccin-mocha", .dark: "solarized-light"]
        )

        try AppPrefs.save(values, to: path)

        XCTAssertEqual(AppPrefs.load(from: path), values)
        XCTAssertEqual(AppPrefs.load(from: path).themes, [.light: "catppuccin-mocha", .dark: "solarized-light"])
    }

    /// S26 — another preference saved must not drop a theme.
    func testChangingTheGuardKeepsTheThemes() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        try data(#"{"warn_before_quit":true,"theme_light":"github-light","theme_dark":"github-dark"}"#)
            .write(to: URL(fileURLWithPath: path))

        var values = AppPrefs.load(from: path)
        values.warnBeforeQuit = false
        try AppPrefs.save(values, to: path)

        XCTAssertEqual(
            AppPrefs.load(from: path),
            Values(warnBeforeQuit: false, themes: [.light: "github-light", .dark: "github-dark"])
        )
    }

    /// S26 — and a theme saved must not drop another preference.
    func testChangingAThemeKeepsTheGuardAFontASizeTheAppearanceAndTheOtherTheme() throws {
        let path = try scratchDirectory() + "/app-prefs.json"
        let before = #"{"warn_before_quit":false,"terminal_font":"Menlo","terminal_font_size":20,"#
            + #""theme":"auto","theme_light":"github-light"}"#
        try data(before).write(to: URL(fileURLWithPath: path))

        var values = AppPrefs.load(from: path)
        values.themes[.dark] = "catppuccin-mocha"
        try AppPrefs.save(values, to: path)

        XCTAssertEqual(
            AppPrefs.load(from: path),
            Values(
                warnBeforeQuit: false, fonts: [.terminal: "Menlo"], fontSizes: [.terminal: 20], theme: .auto,
                themes: [.light: "github-light", .dark: "catppuccin-mocha"]
            )
        )
    }

    /// S27 — whole, the file reads with its themes and the guard off, so a
    /// lenient parser fails here.
    func testADamagedFileHasNoThemes() {
        let whole = #"{"warn_before_quit":false,"theme":"auto","theme_light":"github-light","#
            + #""theme_dark":"solarized-dark"}"#
        XCTAssertEqual(AppPrefs.decode(data(whole)).themes, [.light: "github-light", .dark: "solarized-dark"])

        let damaged = AppPrefs.decode(data(String(whole.dropLast())))

        XCTAssertEqual(damaged, Values())
        XCTAssertEqual(damaged.themes, [:])
        XCTAssertTrue(damaged.warnBeforeQuit)
    }
}
