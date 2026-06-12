import XCTest
import TarmacKit

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

    // MARK: - Dock order

    func testRestoreOrderIsDockOrderAndDeduped() {
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
        store.onFileChange = { _ in fired = true }
        store.applyFileEvent(path: "/r/ghost.md", mtimeMs: 1)
        XCTAssertEqual(store.docs.map(\.path), ["/r/a.md"])
        XCTAssertFalse(fired)
    }

    // MARK: - Recency (⌘P)

    func testEmptyStoreHasNoRecentDoc() {
        XCTAssertNil(DocStore().mostRecentPath)
    }

    func testRestoreSeedsRecencyFromOpenAndChangeTimes() {
        let store = DocStore()
        store.applyRestore([
            doc("/r/a.md", lastChangedMs: 500, lastOpenedMs: 100), // key 500
            doc("/r/b.md", lastOpenedMs: 900),                     // key 900
            doc("/r/c.md", lastOpenedMs: 200),                     // key 200
        ])
        XCTAssertEqual(store.mostRecentPath, "/r/b.md")
    }

    func testRestoreRecencyTiesBreakByDockOrder() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md"), doc("/r/b.md"), doc("/r/c.md")])
        // All keys 0 (M0-era entries): the last dock doc wins.
        XCTAssertEqual(store.mostRecentPath, "/r/c.md")
    }

    func testDocOpenedAndFileEventBumpRecency() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md", lastOpenedMs: 100), doc("/r/b.md", lastOpenedMs: 200)])

        store.applyDocOpened(doc("/r/a.md", lastOpenedMs: 300))
        XCTAssertEqual(store.mostRecentPath, "/r/a.md")

        store.applyFileEvent(path: "/r/b.md", mtimeMs: 400)
        XCTAssertEqual(store.mostRecentPath, "/r/b.md")

        // A live bump outranks any restored timestamp.
        store.applyDocOpened(doc("/r/c.md"))
        XCTAssertEqual(store.mostRecentPath, "/r/c.md")
    }

    // MARK: - Read transitions

    func testMarkReadFlipsOnceAndNotifiesOnce() {
        let store = DocStore()
        store.applyRestore([doc("/r/a.md", read: false)])
        var changes = 0
        store.onChange = { changes += 1 }

        store.markRead("/r/a.md")
        XCTAssertEqual(store.doc(for: "/r/a.md")?.read, true)
        XCTAssertEqual(changes, 1)

        store.markRead("/r/a.md") // idempotent, no notification
        store.markRead("/r/none.md")
        XCTAssertEqual(changes, 1)
    }

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

    // MARK: - Recent window

    func testIsRecentBoundary() {
        XCTAssertFalse(DocStore.isRecent(lastChangedMs: nil, nowMs: 1000))
        XCTAssertTrue(DocStore.isRecent(lastChangedMs: 1000, nowMs: 1000 + 29_999))
        XCTAssertFalse(DocStore.isRecent(lastChangedMs: 1000, nowMs: 1000 + 30_000))
    }

    // MARK: - Display derivations

    func testDisplayPathInsideRepo() {
        let d = doc("/w/payments-api/docs/handoff.md", repo: "payments-api", repoRoot: "/w/payments-api")
        XCTAssertEqual(d.displayRepoName, "payments-api")
        XCTAssertEqual(d.repoRelativePath, "docs/handoff.md")
        XCTAssertEqual(d.displayPath, "payments-api/docs/handoff.md")
        XCTAssertEqual(d.groupKey, "/w/payments-api")
    }

    func testDisplayPathOutsideRepoFallsBackToParentDir() {
        let d = doc("/Users/x/notes/todo.md")
        XCTAssertEqual(d.displayRepoName, "notes")
        XCTAssertEqual(d.displayPath, "notes/todo.md")
        XCTAssertEqual(d.groupKey, "/Users/x/notes")
    }

    // MARK: - Index grouping

    func testGroupsByFirstAppearanceKeepingDockOrderWithin() {
        let docs = [
            doc("/w/api/docs/a.md", repo: "api", repoRoot: "/w/api", repoColor: 3),
            doc("/w/infra/run.md", repo: "infra", repoRoot: "/w/infra", repoColor: 1),
            doc("/w/api/docs/b.md", repo: "api", repoRoot: "/w/api", repoColor: 3),
        ]
        let groups = DocStore.groups(of: docs)
        XCTAssertEqual(groups.map(\.name), ["api", "infra"])
        XCTAssertEqual(groups[0].docs.map(\.path), ["/w/api/docs/a.md", "/w/api/docs/b.md"])
        XCTAssertEqual(groups[0].colorIndex, 3)
    }

    func testTwoReposSharingANameGroupSeparately() {
        let docs = [
            doc("/w/one/api/a.md", repo: "api", repoRoot: "/w/one/api"),
            doc("/w/two/api/b.md", repo: "api", repoRoot: "/w/two/api"),
        ]
        XCTAssertEqual(DocStore.groups(of: docs).count, 2)
    }

    func testItemLabelsFallBackToRelativePathOnBasenameCollision() {
        let group = DocStore.groups(of: [
            doc("/w/api/docs/plan.md", repo: "api", repoRoot: "/w/api"),
            doc("/w/api/archive/plan.md", repo: "api", repoRoot: "/w/api"),
            doc("/w/api/readme.md", repo: "api", repoRoot: "/w/api"),
        ])[0]
        XCTAssertEqual(
            DocStore.itemLabels(for: group),
            ["docs/plan.md", "archive/plan.md", "readme.md"]
        )
    }
}
