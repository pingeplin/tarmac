import XCTest
import TarmacKit

/// Every hex string here is what `tarmac_protocol::encode` (rmp_serde
/// `to_vec_named`) emits for the `Msg` named above it — captured from the Rust
/// crate, never hand-written. docs/protocol.md only requires that frames decode;
/// pinning the bytes as well means a frame the Swift app sends is one the
/// daemon's own suite already exercises: `t` first, then the struct's fields in
/// declaration order, `nil` for an `Option` the Rust side does not skip.
final class RustEncoderParityTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func assertParity(
        _ message: Message,
        _ rustHex: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let payload = hexData(rustHex)
        XCTAssertEqual(try Message.decode(payload: payload), message, file: file, line: line)
        XCTAssertEqual(hex(message.encodedPayload()), hex(payload), file: file, line: line)
    }

    func testHandshake() {
        // Msg::Hello { role: "cli", v: 1, app_version: None }
        assertParity(
            .hello(role: "cli", v: 1),
            "83 a1 74 a5 68 65 6c 6c 6f a4 72 6f 6c 65 a3 63 6c 69 a1 76 01"
        )
        // Msg::Ack
        assertParity(.ack, "81 a1 74 a3 61 63 6b")
        // Msg::Err { msg: "boom" }
        assertParity(.err(msg: "boom"), "82 a1 74 a3 65 72 72 a3 6d 73 67 a4 62 6f 6f 6d")
    }

    func testDocVerbs() {
        // Msg::Open { path: "/a.md", term_id: None, board_id: None }
        assertParity(
            .open(path: "/a.md", termID: nil),
            "82 a1 74 a4 6f 70 65 6e a4 70 61 74 68 a5 2f 61 2e 6d 64"
        )
        // Msg::DocRead { path: "/a.md" }
        assertParity(
            .docRead(path: "/a.md"),
            "82 a1 74 a8 64 6f 63 5f 72 65 61 64 a4 70 61 74 68 a5 2f 61 2e 6d 64"
        )
    }

    func testLayout() {
        // Conformance vector 6, which Rust re-encodes byte-for-byte
        // (`m3_keyless_layout_decodes_board_id_none`).
        assertParity(
            .layout(
                dock: ["/a.md"],
                tiles: [LayoutTile(kind: "term"), LayoutTile(kind: "doc", path: "/a.md")],
                board: nil,
                boardID: nil
            ),
            """
            83 a1 74 a6 6c 61 79 6f 75 74 a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64 a5 74
            69 6c 65 73 92 81 a4 6b 69 6e 64 a4 74 65 72 6d 82 a4 6b 69 6e 64 a3 64
            6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64
            """
        )
        // Conformance vector 8.
        assertParity(
            .layout(
                dock: ["/a.md"],
                tiles: [LayoutTile(kind: "doc", path: "/a.md", x: 120, y: 80, w: 470, h: 330, z: 2)],
                board: BoardViewport(zoom: 0.82, cx: 640, cy: 360),
                boardID: nil
            ),
            """
            84 a1 74 a6 6c 61 79 6f 75 74 a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64 a5 74
            69 6c 65 73 91 87 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e
            6d 64 a1 78 cb 40 5e 00 00 00 00 00 00 a1 79 cb 40 54 00 00 00 00 00 00
            a1 77 cb 40 7d 60 00 00 00 00 00 a1 68 cb 40 74 a0 00 00 00 00 00 a1 7a
            02 a5 62 6f 61 72 64 83 a4 7a 6f 6f 6d cb 3f ea 3d 70 a3 d7 0a 3d a2 63
            78 cb 40 84 00 00 00 00 00 00 a2 63 79 cb 40 76 80 00 00 00 00 00
            """
        )
        // Msg::Layout { dock: ["/b.md"], tiles: [
        //   Tile { kind: "term", x: 92.0, y: 108.5, w: 470.0, h: 330.0, z: 0, term_id: "t1" },
        //   Tile { kind: "doc", path: "/c.md", z: -3, loose: true, shelf: false }],
        //   board: BoardViewport { zoom: 1.0, cx: 0.0, cy: -12.25 }, board_id: "board-1" }
        assertParity(
            .layout(
                dock: ["/b.md"],
                tiles: [
                    LayoutTile(kind: "term", x: 92, y: 108.5, w: 470, h: 330, z: 0, termID: "t1"),
                    LayoutTile(kind: "doc", path: "/c.md", z: -3, loose: true, shelf: false),
                ],
                board: BoardViewport(zoom: 1.0, cx: 0, cy: -12.25),
                boardID: "board-1"
            ),
            """
            85 a1 74 a6 6c 61 79 6f 75 74 a4 64 6f 63 6b 91 a5 2f 62 2e 6d 64 a5 74
            69 6c 65 73 92 87 a4 6b 69 6e 64 a4 74 65 72 6d a1 78 cb 40 57 00 00 00
            00 00 00 a1 79 cb 40 5b 20 00 00 00 00 00 a1 77 cb 40 7d 60 00 00 00 00
            00 a1 68 cb 40 74 a0 00 00 00 00 00 a1 7a 00 a7 74 65 72 6d 5f 69 64 a2
            74 31 85 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 63 2e 6d 64 a1
            7a fd a5 6c 6f 6f 73 65 c3 a5 73 68 65 6c 66 c2 a5 62 6f 61 72 64 83 a4
            7a 6f 6f 6d cb 3f f0 00 00 00 00 00 00 a2 63 78 cb 00 00 00 00 00 00 00
            00 a2 63 79 cb c0 28 80 00 00 00 00 00 a8 62 6f 61 72 64 5f 69 64 a7 62
            6f 61 72 64 2d 31
            """
        )
    }

    func testRestore() {
        // Msg::Restore { docs: [], tiles: [], board: None, board_id: None, live_terms: [] }
        // — `tiles` has no skip, `live_terms` skips when empty.
        assertParity(
            .restore(docs: [], tiles: [], board: nil, boardID: nil, liveTerms: []),
            "83 a1 74 a7 72 65 73 74 6f 72 65 a4 64 6f 63 73 90 a5 74 69 6c 65 73 90"
        )
        // Msg::Restore { docs: [m0 entry "/a.md" via "cli", the full "/b.md" entry],
        //   tiles: [{kind:"term"}], board: {1.0, 0.0, 0.0}, board_id: "board-2",
        //   live_terms: ["t1", "t2"] }
        assertParity(
            .restore(
                docs: [
                    RestoreDoc(path: "/a.md", via: "cli"),
                    RestoreDoc(
                        path: "/b.md",
                        via: "user",
                        repo: "payments-api",
                        repoRoot: "/Users/x/payments-api",
                        repoColor: 3,
                        read: false,
                        lastChangedMs: 1_765_432_100_123,
                        lastOpenedMs: 1_765_432_100_456,
                        termID: "t1"
                    ),
                ],
                tiles: [LayoutTile(kind: "term")],
                board: BoardViewport(zoom: 1.0, cx: 0, cy: 0),
                boardID: "board-2",
                liveTerms: ["t1", "t2"]
            ),
            """
            86 a1 74 a7 72 65 73 74 6f 72 65 a4 64 6f 63 73 92 88 a4 70 61 74 68 a5
            2f 61 2e 6d 64 a3 76 69 61 a3 63 6c 69 a4 72 65 70 6f c0 a9 72 65 70 6f
            5f 72 6f 6f 74 c0 aa 72 65 70 6f 5f 63 6f 6c 6f 72 c0 a4 72 65 61 64 c3
            af 6c 61 73 74 5f 63 68 61 6e 67 65 64 5f 6d 73 c0 ae 6c 61 73 74 5f 6f
            70 65 6e 65 64 5f 6d 73 c0 89 a4 70 61 74 68 a5 2f 62 2e 6d 64 a3 76 69
            61 a4 75 73 65 72 a4 72 65 70 6f ac 70 61 79 6d 65 6e 74 73 2d 61 70 69
            a9 72 65 70 6f 5f 72 6f 6f 74 b5 2f 55 73 65 72 73 2f 78 2f 70 61 79 6d
            65 6e 74 73 2d 61 70 69 aa 72 65 70 6f 5f 63 6f 6c 6f 72 03 a4 72 65 61
            64 c2 af 6c 61 73 74 5f 63 68 61 6e 67 65 64 5f 6d 73 cf 00 00 01 9b 0b
            f4 05 1b ae 6c 61 73 74 5f 6f 70 65 6e 65 64 5f 6d 73 cf 00 00 01 9b 0b
            f4 06 68 a7 74 65 72 6d 5f 69 64 a2 74 31 a5 74 69 6c 65 73 91 81 a4 6b
            69 6e 64 a4 74 65 72 6d a5 62 6f 61 72 64 83 a4 7a 6f 6f 6d cb 3f f0 00
            00 00 00 00 00 a2 63 78 cb 00 00 00 00 00 00 00 00 a2 63 79 cb 00 00 00
            00 00 00 00 00 a8 62 6f 61 72 64 5f 69 64 a7 62 6f 61 72 64 2d 32 aa 6c
            69 76 65 5f 74 65 72 6d 73 92 a2 74 31 a2 74 32
            """
        )
    }

    func testTerminalIO() {
        // Msg::SpawnTerm { term_id: "t2", cols: 80, rows: 24, cwd: None, cmd: None,
        //   board_id: None, inherit_cwd_from: None } — `cwd`/`cmd` have no skip.
        assertParity(
            .spawnTerm(termID: "t2", cols: 80, rows: 24, cwd: nil, cmd: nil),
            """
            86 a1 74 aa 73 70 61 77 6e 5f 74 65 72 6d a7 74 65 72 6d 5f 69 64 a2 74
            32 a4 63 6f 6c 73 50 a4 72 6f 77 73 18 a3 63 77 64 c0 a3 63 6d 64 c0
            """
        )
        // Msg::Input { term_id: "t1", bytes: b"ls\n" } — conformance vector 3.
        assertParity(
            .input(termID: "t1", bytes: Data("ls\n".utf8)),
            """
            83 a1 74 a5 69 6e 70 75 74 a7 74 65 72 6d 5f 69 64 a2 74 31 a5 62 79 74
            65 73 c4 03 6c 73 0a
            """
        )
        // Msg::Output { term_id: "t1", bytes: b"hello\r\n" }
        assertParity(
            .output(termID: "t1", bytes: Data("hello\r\n".utf8)),
            """
            83 a1 74 a6 6f 75 74 70 75 74 a7 74 65 72 6d 5f 69 64 a2 74 31 a5 62 79
            74 65 73 c4 07 68 65 6c 6c 6f 0d 0a
            """
        )
        // Msg::Resize { term_id: "t1", cols: 120, rows: 40 } — conformance vector 4.
        assertParity(
            .resize(termID: "t1", cols: 120, rows: 40),
            """
            84 a1 74 a6 72 65 73 69 7a 65 a7 74 65 72 6d 5f 69 64 a2 74 31 a4 63 6f
            6c 73 78 a4 72 6f 77 73 28
            """
        )
        // Msg::TermClose { term_id: "t1" } — conformance vector 9.
        assertParity(
            .termClose(termID: "t1"),
            "82 a1 74 aa 74 65 72 6d 5f 63 6c 6f 73 65 a7 74 65 72 6d 5f 69 64 a2 74 31"
        )
    }

    func testExit() {
        // Msg::Exit { term_id: "t1", code: Some(0) }
        assertParity(
            .exit(termID: "t1", code: 0),
            "83 a1 74 a4 65 78 69 74 a7 74 65 72 6d 5f 69 64 a2 74 31 a4 63 6f 64 65 00"
        )
        // Msg::Exit { term_id: "t1", code: Some(-1) }
        assertParity(
            .exit(termID: "t1", code: -1),
            "83 a1 74 a4 65 78 69 74 a7 74 65 72 6d 5f 69 64 a2 74 31 a4 63 6f 64 65 ff"
        )
        // Msg::Exit { term_id: "t1", code: None } — `code` has no skip.
        assertParity(
            .exit(termID: "t1", code: nil),
            "83 a1 74 a4 65 78 69 74 a7 74 65 72 6d 5f 69 64 a2 74 31 a4 63 6f 64 65 c0"
        )
    }

    func testDocOpened() {
        // Msg::DocOpened(DocEntry { path: "/a.md", via: "cli", read: true, .. all None })
        assertParity(
            .docOpened(doc: RestoreDoc(path: "/a.md", via: "cli")),
            """
            89 a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64 a4 70 61 74 68 a5 2f 61 2e 6d
            64 a3 76 69 61 a3 63 6c 69 a4 72 65 70 6f c0 a9 72 65 70 6f 5f 72 6f 6f
            74 c0 aa 72 65 70 6f 5f 63 6f 6c 6f 72 c0 a4 72 65 61 64 c3 af 6c 61 73
            74 5f 63 68 61 6e 67 65 64 5f 6d 73 c0 ae 6c 61 73 74 5f 6f 70 65 6e 65
            64 5f 6d 73 c0
            """
        )
        // Conformance vector 7's structure as Rust re-encodes it: the two keys the
        // vector omits (`repo_root`, `last_changed_ms`) come back as explicit nils.
        assertParity(
            .docOpened(doc: RestoreDoc(
                path: "/a.md",
                via: "cli",
                repo: "api",
                repoColor: 3,
                read: false,
                lastOpenedMs: 1_718_000_000_000
            )),
            """
            89 a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64 a4 70 61 74 68 a5 2f 61 2e 6d
            64 a3 76 69 61 a3 63 6c 69 a4 72 65 70 6f a3 61 70 69 a9 72 65 70 6f 5f
            72 6f 6f 74 c0 aa 72 65 70 6f 5f 63 6f 6c 6f 72 03 a4 72 65 61 64 c2 af
            6c 61 73 74 5f 63 68 61 6e 67 65 64 5f 6d 73 c0 ae 6c 61 73 74 5f 6f 70
            65 6e 65 64 5f 6d 73 cf 00 00 01 90 00 c7 9c 00
            """
        )
        // Msg::DocOpened(DocEntry { path: "/a.md", via: "user", repo: "infra",
        //   repo_root: "/Users/x/infra", repo_color: 1, read: true,
        //   last_changed_ms: 1_765_432_100_000, last_opened_ms: 1_765_432_100_123,
        //   term_id: "term-42" })
        assertParity(
            .docOpened(doc: RestoreDoc(
                path: "/a.md",
                via: "user",
                repo: "infra",
                repoRoot: "/Users/x/infra",
                repoColor: 1,
                read: true,
                lastChangedMs: 1_765_432_100_000,
                lastOpenedMs: 1_765_432_100_123,
                termID: "term-42"
            )),
            """
            8a a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64 a4 70 61 74 68 a5 2f 61 2e 6d
            64 a3 76 69 61 a4 75 73 65 72 a4 72 65 70 6f a5 69 6e 66 72 61 a9 72 65
            70 6f 5f 72 6f 6f 74 ae 2f 55 73 65 72 73 2f 78 2f 69 6e 66 72 61 aa 72
            65 70 6f 5f 63 6f 6c 6f 72 01 a4 72 65 61 64 c3 af 6c 61 73 74 5f 63 68
            61 6e 67 65 64 5f 6d 73 cf 00 00 01 9b 0b f4 04 a0 ae 6c 61 73 74 5f 6f
            70 65 6e 65 64 5f 6d 73 cf 00 00 01 9b 0b f4 05 1b a7 74 65 72 6d 5f 69
            64 a7 74 65 72 6d 2d 34 32
            """
        )
    }

    func testHonestSignals() {
        // Msg::FileEvent { path: "/a.md", mtime_ms: 1_765_432_100_123 }
        assertParity(
            .fileEvent(path: "/a.md", mtimeMs: 1_765_432_100_123),
            """
            83 a1 74 aa 66 69 6c 65 5f 65 76 65 6e 74 a4 70 61 74 68 a5 2f 61 2e 6d
            64 a8 6d 74 69 6d 65 5f 6d 73 cf 00 00 01 9b 0b f4 05 1b
            """
        )
        // Msg::TermProc { term_id: "t1", name: "zsh", pid: Some(4242) }
        assertParity(
            .termProc(termID: "t1", name: "zsh", pid: 4242),
            """
            84 a1 74 a9 74 65 72 6d 5f 70 72 6f 63 a7 74 65 72 6d 5f 69 64 a2 74 31
            a4 6e 61 6d 65 a3 7a 73 68 a3 70 69 64 cd 10 92
            """
        )
        // Msg::TermProc { term_id: "t1", name: "vim", pid: None } — `pid` skips.
        assertParity(
            .termProc(termID: "t1", name: "vim", pid: nil),
            """
            83 a1 74 a9 74 65 72 6d 5f 70 72 6f 63 a7 74 65 72 6d 5f 69 64 a2 74 31
            a4 6e 61 6d 65 a3 76 69 6d
            """
        )
        // Msg::Bell { term_id: "t1" }
        assertParity(.bell(termID: "t1"), "82 a1 74 a4 62 65 6c 6c a7 74 65 72 6d 5f 69 64 a2 74 31")
    }

    func testBoards() {
        // Msg::BoardList { boards: [{board-0}, {board-1, name: "infra", running: 2},
        //   {board-2, running: 0}], active: "board-1" }
        assertParity(
            .boardList(
                boards: [
                    BoardMeta(boardID: "board-0"),
                    BoardMeta(boardID: "board-1", name: "infra", running: 2),
                    BoardMeta(boardID: "board-2", running: 0),
                ],
                active: "board-1"
            ),
            """
            83 a1 74 aa 62 6f 61 72 64 5f 6c 69 73 74 a6 62 6f 61 72 64 73 93 81 a8
            62 6f 61 72 64 5f 69 64 a7 62 6f 61 72 64 2d 30 83 a8 62 6f 61 72 64 5f
            69 64 a7 62 6f 61 72 64 2d 31 a4 6e 61 6d 65 a5 69 6e 66 72 61 a7 72 75
            6e 6e 69 6e 67 02 82 a8 62 6f 61 72 64 5f 69 64 a7 62 6f 61 72 64 2d 32
            a7 72 75 6e 6e 69 6e 67 00 a6 61 63 74 69 76 65 a7 62 6f 61 72 64 2d 31
            """
        )
        // Msg::BoardSwitch { board_id: "board-1" }
        assertParity(
            .boardSwitch(boardID: "board-1"),
            """
            82 a1 74 ac 62 6f 61 72 64 5f 73 77 69 74 63 68 a8 62 6f 61 72 64 5f 69
            64 a7 62 6f 61 72 64 2d 31
            """
        )
        // Msg::BoardCreate
        assertParity(.boardCreate, "81 a1 74 ac 62 6f 61 72 64 5f 63 72 65 61 74 65")
        // Msg::BoardRename { board_id: "board-1", name: "infra" }
        assertParity(
            .boardRename(boardID: "board-1", name: "infra"),
            """
            83 a1 74 ac 62 6f 61 72 64 5f 72 65 6e 61 6d 65 a8 62 6f 61 72 64 5f 69
            64 a7 62 6f 61 72 64 2d 31 a4 6e 61 6d 65 a5 69 6e 66 72 61
            """
        )
        // Msg::BoardRename { board_id: "board-1", name: "" }
        assertParity(
            .boardRename(boardID: "board-1", name: ""),
            """
            83 a1 74 ac 62 6f 61 72 64 5f 72 65 6e 61 6d 65 a8 62 6f 61 72 64 5f 69
            64 a7 62 6f 61 72 64 2d 31 a4 6e 61 6d 65 a0
            """
        )
        // Msg::BoardDelete { board_id: "board-1" }
        assertParity(
            .boardDelete(boardID: "board-1"),
            """
            82 a1 74 ac 62 6f 61 72 64 5f 64 65 6c 65 74 65 a8 62 6f 61 72 64 5f 69
            64 a7 62 6f 61 72 64 2d 31
            """
        )
    }
}
