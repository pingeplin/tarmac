import XCTest
@testable import TarmacKit

@MainActor
final class DocStoreTests: XCTestCase {
    private func doc(
        _ path: String,
        via: String = "cli",
        repo: String? = nil,
        repoRoot: String? = nil,
        repoColor: Int? = nil,
        read: Bool = false,
        lastChangedMs: UInt64? = nil,
        lastOpenedMs: UInt64? = nil
    ) -> RestoreDoc {
        RestoreDoc(
            path: path, via: via, repo: repo, repoRoot: repoRoot, repoColor: repoColor,
            read: read, lastChangedMs: lastChangedMs, lastOpenedMs: lastOpenedMs
        )
    }

    // MARK: - Order

    func testRestoreKeepsTheDaemonsOrderAndDedupes() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md"), doc("/r/b.md"), doc("/r/a.md"), doc("/r/c.md")])
        XCTAssertEqual(store.docs.map(\.path), ["/r/a.md", "/r/b.md", "/r/c.md"])
    }

    func testDocOpenedAppendsNewAndNeverMovesExisting() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md"), doc("/r/b.md")])

        XCTAssertTrue(store.applyDocOpened(doc("/r/c.md")))
        XCTAssertEqual(store.docs.map(\.path), ["/r/a.md", "/r/b.md", "/r/c.md"])

        // Re-open updates in place, keeps the slot.
        XCTAssertFalse(store.applyDocOpened(doc("/r/a.md", read: false, lastOpenedMs: 99)))
        XCTAssertEqual(store.docs.map(\.path), ["/r/a.md", "/r/b.md", "/r/c.md"])
        XCTAssertEqual(store.doc(for: "/r/a.md")?.lastOpenedMs, 99)
    }

    func testFileEventForUnregisteredPathIsIgnored() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md")])
        var fired = false
        store.onChange = { fired = true }
        store.applyFileEvent(path: "/r/ghost.md", mtimeMs: 1)
        XCTAssertEqual(store.docs.map(\.path), ["/r/a.md"])
        XCTAssertFalse(fired)
    }

    // MARK: - Read state

    func testReopenedDocCarriesDaemonReadState() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md", read: true)])
        // A cli re-open re-arms unread (daemon-decided; the entry is the truth).
        store.applyDocOpened(doc("/r/a.md", read: false))
        XCTAssertEqual(store.doc(for: "/r/a.md")?.read, false)
    }

    func testFileEventDoesNotTouchRead() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md", read: true)])
        store.applyFileEvent(path: "/r/a.md", mtimeMs: 7)
        XCTAssertEqual(store.doc(for: "/r/a.md")?.read, true)
        XCTAssertEqual(store.doc(for: "/r/a.md")?.lastChangedMs, 7)
    }

    // MARK: - Close

    func testRemoveDropsTheDocAndItsSlot() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md"), doc("/r/b.md"), doc("/r/c.md")])
        var changes = 0
        store.onChange = { changes += 1 }
        store.remove("/r/b.md")
        XCTAssertEqual(store.docs.map(\.path), ["/r/a.md", "/r/c.md"])
        XCTAssertNil(store.doc(for: "/r/b.md"))
        XCTAssertEqual(store.doc(for: "/r/c.md")?.path, "/r/c.md")
        XCTAssertEqual(changes, 1)
    }

    func testRemovingAnUnknownDocChangesNothing() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md")])
        var changes = 0
        store.onChange = { changes += 1 }
        store.remove("/r/zzz.md")
        XCTAssertEqual(store.docs.map(\.path), ["/r/a.md"])
        XCTAssertEqual(changes, 0)
    }

    // MARK: - Re-open

    /// A re-open that names no repo, owner or change time keeps what the doc had.
    func testAReopenKeepsWhatTheNewEntryLeavesOut() {
        let store = DocStore()
        var first = doc("/r/a.md", repo: "api", repoRoot: "/r", repoColor: 2, lastChangedMs: 77)
        first.termID = "t1"
        store.applyDocOpened(first)
        store.applyDocOpened(doc("/r/a.md", via: "user"))
        let kept = store.doc(for: "/r/a.md")
        XCTAssertEqual(kept?.repo, "api")
        XCTAssertEqual(kept?.repoRoot, "/r")
        XCTAssertEqual(kept?.repoColor, 2)
        XCTAssertEqual(kept?.termID, "t1")
        XCTAssertEqual(kept?.lastChangedMs, 77)
        XCTAssertEqual(kept?.via, "user")
    }

    func testAReopenTakesWhatTheNewEntryCarries() {
        let store = DocStore()
        var first = doc("/r/a.md", repoColor: 2, lastChangedMs: 77)
        first.termID = "t1"
        store.applyDocOpened(first)
        var second = doc("/r/a.md", repoColor: 3, lastChangedMs: 99)
        second.termID = "t2"
        store.applyDocOpened(second)
        let kept = store.doc(for: "/r/a.md")
        XCTAssertEqual(kept?.repoColor, 3)
        XCTAssertEqual(kept?.termID, "t2")
        XCTAssertEqual(kept?.lastChangedMs, 99)
    }
}
