import XCTest
@testable import TarmacKit

/// Spec 2610.0009: the one file operation of the themes, on a folder of its
/// own for each test.
final class ThemeFolderTests: XCTestCase {
    private var root: URL!
    private var folder: String { root.appendingPathComponent("themes").path }
    private let text = Data(ThemeFixture.dracula.utf8)

    override func setUpWithError() throws {
        // Short: a test binds a socket in the folder, and a socket's path has
        // 104 bytes at most.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarmac-themes-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func write(_ contents: Data, _ name: String) throws {
        try contents.write(to: URL(fileURLWithPath: path(name)))
    }

    private func permissions(_ mode: Int, _ path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    /// S27 — the call returns: the pipe is not read or waited on.
    func testS27OnlyTheRegularFilesOfTheFolderAreRead() throws {
        let outside = root.appendingPathComponent("outside").path
        try text.write(to: URL(fileURLWithPath: outside))
        try write(text, "Dracula")
        try write(text, ".hidden")
        try write(text, "Old~")
        try FileManager.default.createDirectory(atPath: path("sub"), withIntermediateDirectories: false)
        try write(text, "sub/Inner")
        try FileManager.default.createSymbolicLink(atPath: path("Linked"), withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: path("Dangling"), withDestinationPath: root.path + "/nothing")
        XCTAssertEqual(mkfifo(path("Pipe"), 0o644), 0)
        let exact = Data(repeating: 0x23, count: ThemeFile.sizeLimit)
        try write(exact, "Exact")
        try write(exact + [0x23], "Big")
        try write(Data(), "Empty")
        try write(text, "Locked")
        try permissions(0o000, path("Locked"))
        defer { try? permissions(0o644, path("Locked")) }

        let files = ThemeFolder.files(at: folder)

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.contents) }),
            [
                "Dracula": .success(text), "Linked": .success(text), "Exact": .success(exact),
                "Empty": .success(Data()), "Big": .failure(.tooLarge), "Dangling": .failure(.unreadable),
                "Locked": .failure(.unreadable),
            ]
        )
        XCTAssertEqual(files.count, 7)
    }

    /// S27 — what cannot be opened and is no file gives nothing either: it
    /// is not a theme file that cannot be read.
    func testS27WhatIsNoFileGivesNothingAlsoWhenItCannotBeOpened() throws {
        try write(text, "Dracula")
        let socket = try DevSocket.claim(path: path("Socket")).get()
        defer { socket.close() }
        try FileManager.default.createDirectory(atPath: path("Closed"), withIntermediateDirectories: false)
        try permissions(0o000, path("Closed"))
        defer { try? permissions(0o755, path("Closed")) }
        XCTAssertEqual(mkfifo(path("ClosedPipe"), 0o000), 0)

        XCTAssertEqual(ThemeFolder.files(at: folder), [ThemeLibrary.File(name: "Dracula", contents: .success(text))])
    }

    /// S28
    func testS28AFolderThatIsNotThereHasNoFilesAndIsNotMade() throws {
        let missing = root.appendingPathComponent("missing").path

        XCTAssertEqual(ThemeFolder.files(at: missing), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    /// S28
    func testS28APathThatIsAFileHasNoFiles() throws {
        try write(text, "Dracula")

        XCTAssertEqual(ThemeFolder.files(at: path("Dracula")), [])
        XCTAssertEqual(FileManager.default.contents(atPath: path("Dracula")), text)
    }

    /// S28
    func testS28AFolderThatCannotBeListedHasNoFiles() throws {
        try write(text, "Dracula")
        try permissions(0o000, folder)
        defer { try? permissions(0o755, folder) }

        XCTAssertEqual(ThemeFolder.files(at: folder), [])
    }

    /// S29
    func testS29AChangedFileGivesAnotherLibrary() throws {
        try write(text, "Dracula")
        let first = ThemeLibrary(files: ThemeFolder.files(at: folder))
        XCTAssertEqual(
            first.fileThemes,
            [ThemeCatalog.Entry(id: "file:Dracula", title: "Dracula", palette: ThemeFile.palette(from: ThemeFixture.draculaColours))]
        )

        try write(Data(ThemeFixture.dracula(background: "#1e1f29").utf8), "Dracula")

        XCTAssertNotEqual(ThemeLibrary(files: ThemeFolder.files(at: folder)), first)
    }
}
