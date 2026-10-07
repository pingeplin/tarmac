import XCTest
@testable import TarmacKit

/// Spec 2610.0009: the built-in themes and the themes of a set of files, as
/// one value.
final class ThemeLibraryTests: XCTestCase {
    private let draculaPalette = ThemeFile.palette(from: ThemeFixture.draculaColours)

    private func file(_ name: String, _ text: String = ThemeFixture.dracula) -> ThemeLibrary.File {
        ThemeLibrary.File(name: name, contents: .success(Data(text.utf8)))
    }

    private func dracula(in library: ThemeLibrary, file: StaticString = #filePath, line: UInt = #line) -> ThemeCatalog.Entry {
        guard let entry = library.fileThemes.first(where: { $0.id == "file:Dracula" }) else {
            XCTFail("no file:Dracula", file: file, line: line)
            return ThemeCatalog.all[0]
        }
        return entry
    }

    /// S20
    func testS20ALibraryWithNoFileIsTheCatalogue() {
        XCTAssertEqual(ThemeLibrary.shipped, ThemeLibrary(files: []))
        XCTAssertEqual(ThemeLibrary.shipped.all, ThemeCatalog.all)
        XCTAssertEqual(ThemeLibrary.shipped.refused, [])
    }

    /// S21
    func testS21TheFileThemesFollowTheCatalogueByTitle() {
        let files = [
            file("beta"), file("Alpha"), file("alpha"), file("Zed"), file("broken", "foreground = #fff"),
            ThemeLibrary.File(name: "big", contents: .failure(.tooLarge)),
        ]

        let library = ThemeLibrary(files: files)

        XCTAssertEqual(Array(library.all.prefix(8)), ThemeCatalog.all)
        XCTAssertEqual(
            Array(library.all.dropFirst(8)),
            ["Alpha", "alpha", "beta", "Zed"].map {
                ThemeCatalog.Entry(id: "file:\($0)", title: $0, palette: draculaPalette)
            }
        )
        XCTAssertEqual(
            library.refused,
            [
                ThemeLibrary.Refused(file: "big", refusal: .tooLarge),
                ThemeLibrary.Refused(file: "broken", refusal: .missing(key: "background")),
            ]
        )
        XCTAssertEqual(ThemeLibrary(files: files.reversed()), library)
    }

    /// S13
    func testS13ARefusedFileHasItsDetail() {
        XCTAssertEqual(
            ThemeLibrary.Refused(file: "Dracula", refusal: .missing(key: "foreground")).detail,
            "Dracula: has no foreground"
        )
    }

    /// S22
    func testS22AnIdNamesItsEntryForEitherAppearance() {
        let library = ThemeLibrary(files: [file("Dracula")])
        let entry = dracula(in: library)

        XCTAssertEqual(library.entry("file:Dracula", for: .light), entry)
        XCTAssertEqual(library.entry("file:Dracula", for: .dark), entry)
        XCTAssertEqual(library.entry("catppuccin-mocha", for: .light).title, "Catppuccin Mocha")
        XCTAssertEqual(library.entry("catppuccin-mocha", for: .light).id, "catppuccin-mocha")
    }

    /// S22 — the id is compared exactly.
    func testS22AnIdNoThemeHasGivesTheStandardTheme() {
        let library = ThemeLibrary(files: [file("Dracula")])

        for id in ["file:Gone", "Dracula", "file:dracula", nil] {
            XCTAssertEqual(library.entry(id, for: .light).id, "breeze-light", id ?? "nil")
            XCTAssertEqual(library.entry(id, for: .dark).id, "breeze-dark", id ?? "nil")
        }
    }

    /// S23
    func testS23AFileWithTheTitleOfABuiltInThemeIsAThemeOfItsOwn() {
        let library = ThemeLibrary(files: [file("Catppuccin Mocha")])

        let pair = library.all.filter { $0.title == "Catppuccin Mocha" }

        XCTAssertEqual(pair.map(\.id), ["catppuccin-mocha", "file:Catppuccin Mocha"])
        XCTAssertNotEqual(pair.first?.palette, pair.last?.palette)
        XCTAssertEqual(library.entry("catppuccin-mocha", for: .dark), pair.first)
        XCTAssertEqual(library.entry("file:Catppuccin Mocha", for: .dark), pair.last)
        XCTAssertEqual(pair.map(\.isFromFile), [false, true])
        XCTAssertEqual(ThemeCatalog.all.map(\.isFromFile), Array(repeating: false, count: 8))
    }

    /// S24
    func testS24TheThemeInEffectCanBeAFileTheme() {
        let library = ThemeLibrary(files: [file("Dracula")])
        let entry = dracula(in: library)

        XCTAssertEqual(entry.variant, .dark)
        XCTAssertEqual(library.inEffect(choice: .light, themes: [.light: "file:Dracula"], systemIsDark: false), entry)
        XCTAssertEqual(
            library.inEffect(choice: .light, themes: [.light: "file:Gone"], systemIsDark: false).id, "breeze-light"
        )
        XCTAssertEqual(library.inEffect(choice: .auto, themes: [.dark: "file:Dracula"], systemIsDark: true), entry)
        XCTAssertEqual(
            library.inEffect(choice: .auto, themes: [.dark: "file:Dracula"], systemIsDark: false).id, "breeze-light"
        )
    }

    /// S25
    func testS25WhichNamesAreRead() {
        for name in ["", ".DS_Store", ".Dracula.swp", "Dracula~", "a\u{1}b", "a\nb", "a\u{7f}b"] {
            XCTAssertFalse(ThemeLibrary.reads(name), name.debugDescription)
        }
        for name in ["Dracula", "Catppuccin Mocha", "theme.conf", "~x", "日本"] {
            XCTAssertTrue(ThemeLibrary.reads(name), name)
        }
    }

    /// S26
    func testS26LibrariesAreEqualWhenTheirThemesAre() {
        let library = ThemeLibrary(files: [file("Dracula")])
        let changed = ThemeLibrary(
            files: [file("Dracula", ThemeFixture.dracula.replacingOccurrences(of: "#282a36\nforeground", with: "#282a37\nforeground"))]
        )

        XCTAssertEqual(ThemeLibrary(files: [file("Dracula", "# note\n" + ThemeFixture.dracula)]), library)
        XCTAssertNotEqual(changed, library)
        XCTAssertEqual(dracula(in: changed).palette.terminal.background, 0x282a37)
    }
}
