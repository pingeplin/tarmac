import JavaScriptCore
import XCTest

@testable import TarmacKit

/// The HTML card shim as it ships (`TarmacApp/Resources/Web/card_shim.js`),
/// run in a stand-in window with stand-in schedulers: the scheduler gate of
/// spec 2609.0002, the zoom handshake of spec 2609.0003
/// and the font properties of spec 2610.0010.
///
/// Two rules of the stand-in window make the assertions mean anything:
///
/// - All six scheduler natives are on the window before the shim runs. The
///   shim captures them at load, so a late install would hand it other
///   functions than the ones these tests observe.
/// - Native ids come from one range per family, far above the shim's own
///   counter, which starts at 1. Without that, "the native was called with
///   the native id" cannot be told from a wrapper passing its own id through,
///   and "Pause cancels outstanding native frame request" and "Cancel wrappers are transparent before any cull" pass whatever the shim does.
///
/// "The card calls X" is always spelled `window.X(...)`: the wrappers are
/// installed on `window`, and going through it is what lets "Shim ignores replaced scheduler globals" say which
/// reference a resume uses.
final class CardShimTests: XCTestCase {
    private static let rafIdBase = 1000
    private static let timeoutIdBase = 2000
    private static let intervalIdBase = 3000

    /// The stand-in window, taking the document's `tarmac-zoom` meta, the one
    /// native to leave out, whether the document has a head, and its
    /// `tarmac-data` meta (spec 2611.0002). The window is
    /// the global object, as it is in a page; `h` is what a test drives it
    /// with and reads back from.
    ///
    /// A document with a head is one that elements are added to: it has a
    /// `createElement`, a `MutationObserver` that `h.parse` tells of each
    /// element, and the one query the default colour scheme asks. Without it
    /// the document is the one every test before spec 2610.0007 runs in.
    private static let page = """
        (function (meta, omitNative, withHead, dataMeta) {
          const listeners = new Map();
          const docListeners = new Map();
          const posted = [];
          const rootWrites = [];
          const style = { setProperty(...args) { rootWrites.push(["setProperty", ...args]); } };
          const observers = [];
          const sheets = [];

          const frames = new Map();
          const timeouts = new Map();
          const intervals = new Map();

          let rafSeq = \(rafIdBase);
          let timeoutSeq = \(timeoutIdBase);
          let intervalSeq = \(intervalIdBase);

          const calls = {
            requestAnimationFrame: [],
            cancelAnimationFrame: [],
            setTimeout: [],
            clearTimeout: [],
            setInterval: [],
            clearInterval: [],
          };

          const parent = { postMessage(data) { posted.push(data); } };
          const add = (map, type, fn) => map.set(type, [...(map.get(type) ?? []), fn]);
          const emit = (map, type, event) => { for (const fn of map.get(type) ?? []) fn(event); };

          Object.assign(globalThis, {
            window: globalThis,
            location: { href: "tarmac-card://doc/card.html?v=1" },
            parent,
            addEventListener: (type, fn) => add(listeners, type, fn),
            removeEventListener() {},
            dispatchEvent(event) {
              emit(listeners, event.type, event);
              return true;
            },
            CustomEvent: class {
              constructor(type, init) {
                this.type = type;
                this.detail = init ? init.detail : null;
              }
            },
            scrollBy() {},

            requestAnimationFrame(cb) {
              const id = rafSeq++;
              frames.set(id, cb);
              calls.requestAnimationFrame.push(id);
              return id;
            },
            cancelAnimationFrame(id) {
              calls.cancelAnimationFrame.push(id);
              frames.delete(id);
            },
            setTimeout(cb, delay, ...args) {
              const id = timeoutSeq++;
              timeouts.set(id, { cb, args });
              calls.setTimeout.push({ id, delay, args });
              return id;
            },
            clearTimeout(id) {
              calls.clearTimeout.push(id);
              timeouts.delete(id);
            },
            setInterval(cb, delay) {
              const id = intervalSeq++;
              intervals.set(id, cb);
              calls.setInterval.push({ id, delay });
              return id;
            },
            clearInterval(id) {
              calls.clearInterval.push(id);
              intervals.delete(id);
            },

            console: { log() {}, info() {}, warn() {}, error() {} },

            ResizeObserver: class {
              constructor(callback) {
                this.callback = callback;
                this.observed = [];
                observers.push(this);
              }
              observe(target) { this.observed.push(target); }
            },

            document: {
              documentElement: { style, setAttribute(...args) { rootWrites.push(["setAttribute", ...args]); } },
              addEventListener: (type, fn) => add(docListeners, type, fn),
              querySelector(sel) {
                if (sel === 'meta[name="tarmac-zoom"]' && meta !== null) return { content: meta };
                if (sel === 'meta[name="tarmac-data"]' && dataMeta !== null) return { content: dataMeta };
                return null;
              },
            },
          });
          // A constructed stylesheet with the text and the rules it was given,
          // and the shim as far as it had come when the sheet was made. Left out,
          // as in an engine without them, when `omitNative` is CSSStyleSheet. Its
          // `replaceSync` throws for a text `h.refuse` names, and records it.
          const refused = [];
          if (omitNative !== "CSSStyleSheet") {
            document.adoptedStyleSheets = [];
            globalThis.CSSStyleSheet = class {
              constructor() {
                this.cssRules = [];
                this.atConstruction = { posted: [...posted], listeners: [...listeners.keys()] };
                sheets.push(this);
              }
              replaceSync(text) {
                if (h.refuse && h.refuse(text)) {
                  refused.push(text);
                  throw new Error("refused");
                }
                this.text = text;
                this.cssRules = text === ":root{}" ? [{ selectorText: ":root", style: { values: {}, setProperty(name, value) { this.values[name] = value; } } }] : [];
              }
            };
          }
          const watchers = [];
          let parse;
          if (withHead) {
            const stockLog = console.log;
            // What the window had seen of the shim when the head got its first
            // child. It is read from what the stand-in already keeps, so the
            // document without a head is not changed to record an order.
            const seen = () => [
              ...(posted.length === 0 ? [] : ["parent postMessage"]),
              ...(console.log === stockLog ? [] : ["console"]),
              ...[...listeners.keys()].map((type) => `window ${type}`),
              ...[...docListeners.keys()].map((type) => `document ${type}`),
              ...observers.map(() => "ResizeObserver"),
              ...watchers.map(() => "MutationObserver"),
              ...sheets.map(() => "CSSStyleSheet"),
            ];
            // `changes` is the head's history in order: an `append` is a script's
            // (the shim's), a `parse` is the test's.
            const head = {
              children: [],
              changes: [],
              before: null,
              appendChild(el) {
                head.before ??= seen();
                head.children.push(el);
                head.changes.push(`append ${el.localName}`);
                return el;
              },
            };
            const element = (localName, attributes) => ({
              localName,
              ...attributes,
              remove() {
                const at = head.children.indexOf(this);
                if (at < 0) return;
                head.children.splice(at, 1);
                head.changes.push(`remove ${localName}`);
              },
            });

            document.head = head;
            document.createElement = (localName) => element(localName);
            // `meta[name="x"]` and `meta[name="x" i]`, told apart as an engine
            // tells them: a name matches in any letter case only with the `i`.
            document.querySelectorAll = (selector) => {
              const [, name, anyCase] = /^meta\\[name="([^"]*)"( i)?\\]$/.exec(selector) ?? [];
              if (name === undefined) return [];
              const fold = (text) => (anyCase ? text.toLowerCase() : text);
              return head.children.filter(
                (el) => el.localName === "meta" && typeof el.name === "string" && fold(el.name) === fold(name)
              );
            };
            globalThis.MutationObserver = class {
              constructor(callback) {
                this.callback = callback;
                this.observed = [];
                this.connected = false;
                watchers.push(this);
              }
              observe(target, options) {
                this.observed.push({ target, options });
                this.connected = true;
              }
              disconnect() { this.connected = false; }
            };
            // The parser, or a script of the author, puts an element in the head.
            // An observer hears of it only while it is connected.
            parse = (localName, attributes) => {
              const el = element(localName, attributes);
              head.children.push(el);
              head.changes.push(`parse ${localName}`);
              for (const watcher of watchers.filter((each) => each.connected)) {
                watcher.callback([{ type: "childList", target: head, addedNodes: [el] }], watcher);
              }
              return el;
            };
          }
          if (omitNative) delete globalThis[omitNative];

          globalThis.h = {
            posted,
            style,
            rootWrites,
            sheets,
            refuse: null,
            refused,
            calls,
            send: (data, source = parent) => emit(listeners, "message", { source, data }),
            fire: (type, event) => emit(listeners, type, event),
            // Where the shim listens for a scroll is its own business, so the
            // event goes to both; the document is the root's own target.
            scroll(target = document) {
              emit(docListeners, "scroll", { target });
              emit(listeners, "scroll", { target });
            },
            observers,
            watchers,
            parse,
            domReady: () => emit(docListeners, "DOMContentLoaded", {}),
            driveFrame(ts) {
              const due = [...frames.entries()].sort((a, b) => a[0] - b[0]);
              frames.clear();
              for (const [, cb] of due) cb(ts);
            },
            fireTimeout(id) {
              const entry = timeouts.get(id);
              if (!entry) throw new Error(`no pending native timeout ${id}`);
              timeouts.delete(id);
              entry.cb(...entry.args);
            },
            drainTimeouts() {
              for (const id of [...timeouts.keys()].sort((a, b) => a - b)) {
                const entry = timeouts.get(id);
                if (!entry) continue;
                timeouts.delete(id);
                entry.cb(...entry.args);
              }
            },
            tickInterval(id) {
              const cb = intervals.get(id);
              if (!cb) throw new Error(`no armed native interval ${id}`);
              cb();
            },
            pendingFrameIds: () => [...frames.keys()],
            pendingTimeoutIds: () => [...timeouts.keys()],
          };
        })
        """

    /// A stand-in window with the shim loaded in it. Every expression read
    /// back is JavaScript, evaluated in that window.
    private struct Shim {
        let context: JSContext

        @discardableResult
        func run(_ script: String) -> JSValue { context.evaluateScript(script) }

        func pause() { run("h.send({ tarmac: 'cull', culled: true })") }
        func resume() { run("h.send({ tarmac: 'cull', culled: false })") }

        /// Resume and let both flush carriers run — the `setTimeout(..., 0)`
        /// hop, then the catch-up frame — as an engine does once the message
        /// listener has returned.
        func resumeAndDrain(_ ts: Int = 1) {
            resume()
            run("h.drainTimeouts(); h.driveFrame(\(ts));")
        }

        func number(_ expression: String) -> Double? {
            let value = run(expression)
            return value.isNumber ? value.toDouble() : nil
        }

        func flag(_ expression: String) -> Bool? {
            let value = run(expression)
            return value.isBoolean ? value.toBool() : nil
        }

        func id(_ expression: String) throws -> Int {
            try XCTUnwrap(number(expression).flatMap(Int.init(exactly:)), "\(expression) is no id")
        }

        private func elements(_ expression: String) throws -> [JSValue] {
            let value = run(expression)
            let array = try XCTUnwrap(value.isArray ? value : nil, "\(expression) is no array")
            return (0..<Int(array.forProperty("length").toInt32())).map { array.atIndex($0) }
        }

        func count(_ expression: String) throws -> Int { try elements(expression).count }

        func ids(_ expression: String) throws -> [Int] {
            try elements(expression).map {
                try XCTUnwrap($0.isNumber ? Int(exactly: $0.toDouble()) : nil, "\(expression) holds \($0)")
            }
        }

        func strings(_ expression: String) throws -> [String] {
            try elements(expression).map {
                try XCTUnwrap($0.isString ? $0.toString() : nil, "\(expression) holds \($0)")
            }
        }

        func posted() throws -> [NSDictionary] {
            try XCTUnwrap(run("h.posted").toArray() as? [NSDictionary], "a posted message is no object")
        }

        func hasPosted(_ message: [String: Any]) throws -> Bool { try posted().contains(message as NSDictionary) }

        /// The message of what `script` throws, nil when it returns.
        func thrown(_ script: String) -> String? {
            let message = run("(() => { try { \(script); return null; } catch (error) { return error.message; } })()")
            return message.isString ? message.toString() : nil
        }

        /// Whether a frame the card requests now reaches the native.
        func stillRunning() throws -> Bool {
            let before = try count("h.calls.requestAnimationFrame")
            run("window.requestAnimationFrame(() => {})")
            return try count("h.calls.requestAnimationFrame") == before + 1
        }
    }

    /// The `ready` of a document that names no data file (spec 2611.0002).
    private static func ready(meta: String?) -> [String: Any] {
        [
            "tarmac": "ready", "meta": meta as Any? ?? NSNull(), "data": NSNull(),
            "source": "tarmac-card://doc/card.html?v=1",
        ]
    }

    private func source() throws -> String { try CardShimSource.text() }

    private func window(
        meta: String?, omitting native: String? = nil, head: Bool = false, data: String? = nil
    ) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("the script threw: \(String(describing: error))") }
        context.evaluateScript(Self.page)
            .call(withArguments: [meta as Any? ?? NSNull(), native as Any? ?? NSNull(), head, data as Any? ?? NSNull()])
        return context
    }

    /// `before` runs in the window before the shim does.
    private func loadShim(
        meta: String? = "magnify", omitting native: String? = nil, head: Bool = false, fonts: CardFontVariables? = nil,
        data: String? = nil, before: String? = nil
    ) throws -> Shim {
        let context = try window(meta: meta, omitting: native, head: head, data: data)
        if let before { context.evaluateScript(before) }
        let raw = try source()
        context.evaluateScript(fonts?.filling(raw) ?? raw)
        return Shim(context: context)
    }

    // MARK: - the shipped shim loads and still handshakes ("Shim loaded on fake natives posts ready")

    /// "Shim loaded on fake natives posts ready".
    func testPostsReadyWithTheDocumentsOwnMetaAndAppliesAHostZoom() throws {
        let shim = try loadShim(meta: "magnify")

        shim.run("h.domReady()")
        XCTAssertTrue(try shim.hasPosted(Self.ready(meta: "magnify")), "Shim loaded on fake natives posts ready: ready")

        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "Shim loaded on fake natives posts ready: zoom")
    }

    /// "Shim loaded on fake natives posts ready".
    func testReportsANullMetaForADocumentWithNoTarmacZoomTag() throws {
        let shim = try loadShim(meta: nil)
        shim.run("h.domReady()")
        XCTAssertTrue(try shim.hasPosted(Self.ready(meta: nil)), "Shim loaded on fake natives posts ready")
    }

    /// "Shim loaded on fake natives posts ready".
    /// What matters is that the natives exist before the shim runs, so it
    /// captures the functions these tests observe; a `typeof` after load would
    /// only re-check the shim's own wrappers. A shim that could load with one
    /// missing would have captured nothing, and every other scenario would
    /// pass whatever it did.
    func testFailsLoudlyIfASchedulerNativeIsMissingWhenTheShimCaptures() throws {
        for native in ["requestAnimationFrame", "cancelAnimationFrame", "setTimeout", "clearTimeout", "setInterval"] {
            let context = try window(meta: "magnify", omitting: native)
            var thrown: JSValue?
            context.exceptionHandler = { _, error in thrown = error }
            context.evaluateScript(try source())
            XCTAssertNotNil(thrown, "Shim loaded on fake natives posts ready: the shim loaded without \(native)")
        }
    }

    // MARK: - the gate uses the natives captured at load, not the current globals ("Shim ignores replaced scheduler globals")

    /// "Shim ignores replaced scheduler globals".
    /// The callbacks are issued before the globals are replaced: once they
    /// are, card code can no longer reach the wrappers at all.
    func testCancelsAndResumesThroughCapturedReferencesAfterACardReplacesThem() throws {
        let shim = try loadShim()
        shim.run(
            """
            var ran = [];
            window.requestAnimationFrame(() => ran.push("frame"));
            var timeoutId = window.setTimeout(() => ran.push("timeout"), 5);
            """)
        let nativeFrameId = try shim.id("h.calls.requestAnimationFrame[0]")

        shim.run(
            """
            var boom = () => { throw new Error("card replaced a scheduler global"); };
            window.requestAnimationFrame = boom;
            window.setTimeout = boom;
            window.cancelAnimationFrame = boom;
            """)

        shim.pause()
        XCTAssertTrue(
            try shim.ids("h.calls.cancelAnimationFrame").contains(nativeFrameId),
            "Shim ignores replaced scheduler globals: cancel")

        shim.run("h.fireTimeout(timeoutId)")
        XCTAssertEqual(try shim.strings("ran"), [], "Shim ignores replaced scheduler globals: ran while paused")

        shim.resumeAndDrain()
        XCTAssertEqual(
            try shim.strings("ran").sorted(), ["frame", "timeout"], "Shim ignores replaced scheduler globals: resume")
    }

    // MARK: - requestAnimationFrame gate

    /// "Pause cancels outstanding native frame request".
    func testPauseCallsTheNativeCancelAnimationFrameWithTheOutstandingNativeId() throws {
        let shim = try loadShim()
        shim.run("var ran = false; window.requestAnimationFrame(() => { ran = true; });")
        let nativeId = try shim.id("h.calls.requestAnimationFrame[0]")
        XCTAssertGreaterThanOrEqual(
            nativeId, Self.rafIdBase, "Pause cancels outstanding native frame request: a native id")

        shim.pause()

        XCTAssertEqual(
            try shim.ids("h.calls.cancelAnimationFrame"), [nativeId],
            "Pause cancels outstanding native frame request: cancelled")
        XCTAssertEqual(
            try shim.ids("h.pendingFrameIds()"), [], "Pause cancels outstanding native frame request: pending")
        XCTAssertEqual(shim.flag("ran"), false, "Pause cancels outstanding native frame request: ran")
    }

    /// "Paused frame request returns distinct id".
    func testAPausedRAFCallReachesNoNativeAndStillReturnsAUsableId() throws {
        let shim = try loadShim()
        shim.pause()
        let before = try shim.count("h.calls.requestAnimationFrame")

        shim.run("var a = window.requestAnimationFrame(() => {}); var b = window.requestAnimationFrame(() => {});")

        XCTAssertEqual(
            try shim.count("h.calls.requestAnimationFrame"), before,
            "Paused frame request returns distinct id: reached the native")
        XCTAssertFalse(shim.run("a").isUndefined, "Paused frame request returns distinct id: first id")
        XCTAssertFalse(shim.run("b").isUndefined, "Paused frame request returns distinct id: second id")
        XCTAssertEqual(shim.flag("Object.is(a, b)"), false, "Paused frame request returns distinct id: the ids are one")
    }

    /// "Resume makes one native frame request".
    func testResumeIssuesExactlyOneNativeFrameAndDeliversAllHeldCallbacksOnceInOrder() throws {
        let shim = try loadShim()
        shim.run("var ran = []; window.requestAnimationFrame(() => ran.push('pre'));")
        shim.pause()
        shim.run(
            """
            window.requestAnimationFrame(() => ran.push("mid"));
            window.requestAnimationFrame(() => ran.push("post"));
            """)

        let nativeCallsBefore = try shim.count("h.calls.requestAnimationFrame")
        shim.resume()
        XCTAssertEqual(
            try shim.count("h.calls.requestAnimationFrame"), nativeCallsBefore + 1,
            "Resume makes one native frame request: one native frame")

        shim.run("h.driveFrame(1)")
        XCTAssertEqual(
            try shim.strings("ran"), ["pre", "mid", "post"], "Resume makes one native frame request: delivered")
    }

    /// "Cancelled held frame is never delivered".
    func testCancelAnimationFrameOnAHeldIdDropsOnlyThatCallback() throws {
        let shim = try loadShim()
        shim.pause()
        shim.run(
            """
            var ran = [];
            var doomed = window.requestAnimationFrame(() => ran.push("doomed"));
            window.requestAnimationFrame(() => ran.push("kept"));
            window.cancelAnimationFrame(doomed);
            """)
        shim.resumeAndDrain()

        XCTAssertEqual(try shim.strings("ran"), ["kept"], "Cancelled held frame is never delivered")
    }

    /// "Resumed frames receive fresh timestamp".
    func testAReIssuedCallbackReceivesTheFreshCatchUpTimestamp() throws {
        let shim = try loadShim()
        shim.run("var seen = []; window.requestAnimationFrame((ts) => seen.push(ts));")
        shim.pause()
        shim.resume()
        shim.run("h.driveFrame(987)")

        XCTAssertEqual(try shim.ids("seen"), [987], "Resumed frames receive fresh timestamp")
    }

    // MARK: - setInterval gate

    /// "Paused interval delivers nothing".
    func testAPausedIntervalDeliversNothingWhileTheNativeKeepsTicking() throws {
        let shim = try loadShim()
        shim.run("var ticks = 0; window.setInterval(() => { ticks++; }, 16);")
        let nativeId = try shim.id("h.calls.setInterval[0].id")
        XCTAssertGreaterThanOrEqual(nativeId, Self.intervalIdBase, "Paused interval delivers nothing: a native id")

        shim.pause()
        shim.run("h.tickInterval(\(nativeId)); h.tickInterval(\(nativeId)); h.tickInterval(\(nativeId));")

        XCTAssertEqual(shim.number("ticks"), 0, "Paused interval delivers nothing: delivered")
        XCTAssertFalse(
            try shim.ids("h.calls.clearInterval").contains(nativeId),
            "Paused interval delivers nothing: the native was cleared")
    }

    /// "Resumed interval runs once not three times".
    func testMissedTicksAreDroppedNotFlushedOnResume() throws {
        let shim = try loadShim()
        shim.run("var ticks = 0; window.setInterval(() => { ticks++; }, 16);")
        let nativeId = try shim.id("h.calls.setInterval[0].id")

        shim.pause()
        shim.run("h.tickInterval(\(nativeId)); h.tickInterval(\(nativeId)); h.tickInterval(\(nativeId));")

        shim.resumeAndDrain()
        XCTAssertEqual(
            shim.number("ticks"), 0, "Resumed interval runs once not three times: the resume itself delivered")

        shim.run("h.tickInterval(\(nativeId))")
        XCTAssertEqual(
            shim.number("ticks"), 1, "Resumed interval runs once not three times: one tick, not the three missed")
    }

    /// "Interval cleared while paused stays cleared".
    func testClearIntervalWhilePausedReachesTheNativeAndEndsTheInterval() throws {
        let shim = try loadShim()
        shim.run("var ticks = 0; var id = window.setInterval(() => { ticks++; }, 16);")
        let nativeId = try shim.id("h.calls.setInterval[0].id")

        shim.pause()
        shim.run("window.clearInterval(id)")
        XCTAssertTrue(
            try shim.ids("h.calls.clearInterval").contains(nativeId),
            "Interval cleared while paused stays cleared: cleared natively")

        shim.resumeAndDrain()
        XCTAssertEqual(shim.number("ticks"), 0, "Interval cleared while paused stays cleared: delivered")
        XCTAssertEqual(
            shim.thrown("h.tickInterval(\(nativeId))"), "no armed native interval \(nativeId)",
            "Interval cleared while paused stays cleared: still armed"
        )
    }

    // MARK: - setTimeout gate

    /// "Timeout firing during pause is diverted".
    /// Issued while running: a gate at call time would let this one through.
    func testATimeoutWhoseNativeTimerFiresDuringThePauseIsDivertedNotRun() throws {
        let shim = try loadShim()
        shim.run("var ran = false; var id = window.setTimeout(() => { ran = true; }, 16);")

        shim.pause()
        shim.run("h.fireTimeout(id)")

        XCTAssertEqual(shim.flag("ran"), false, "Timeout firing during pause is diverted")
    }

    /// "Diverted timeout runs once after resume".
    func testResumeFlushesItExactlyOnceThroughANativeSetTimeoutZeroHop() throws {
        let shim = try loadShim()
        shim.run("var runs = 0; var id = window.setTimeout(() => { runs++; }, 16);")
        shim.pause()
        shim.run("h.fireTimeout(id)")

        let before = try shim.count("h.calls.setTimeout")
        shim.resume()

        XCTAssertEqual(
            shim.number("runs"), 0, "Diverted timeout runs once after resume: ran inside the message listener")
        XCTAssertFalse(
            shim.run("h.calls.setTimeout[\(before)]").isUndefined, "Diverted timeout runs once after resume: the hop")
        XCTAssertEqual(
            shim.number("h.calls.setTimeout[\(before)].delay"), 0,
            "Diverted timeout runs once after resume: the hop's delay")

        shim.run("h.drainTimeouts()")
        XCTAssertEqual(shim.number("runs"), 1, "Diverted timeout runs once after resume: flushed")

        shim.run("h.drainTimeouts()")
        XCTAssertEqual(shim.number("runs"), 1, "Diverted timeout runs once after resume: flushed twice")
    }

    /// "Diverted timeout keeps extra arguments".
    func testExtraArgumentsSurviveTheDivertAndTheFlush() throws {
        let shim = try loadShim()
        shim.run("var seen = []; var id = window.setTimeout((...args) => seen.push(args), 16, 'a', 7);")
        shim.pause()
        shim.run("h.fireTimeout(id)")
        shim.resumeAndDrain()

        XCTAssertEqual(shim.run("seen").toArray() as NSArray?, [["a", 7]], "Diverted timeout keeps extra arguments")
    }

    /// "Cleared diverted timeout never runs".
    func testClearTimeoutOnADivertedCallbackStopsItRunningAtAnyPoint() throws {
        let shim = try loadShim()
        shim.run("var ran = false; var id = window.setTimeout(() => { ran = true; }, 16);")
        shim.pause()
        shim.run("h.fireTimeout(id)")
        XCTAssertEqual(shim.flag("ran"), false, "Cleared diverted timeout never runs: ran during the pause")

        shim.run("window.clearTimeout(id)")
        shim.resumeAndDrain()

        XCTAssertEqual(shim.flag("ran"), false, "Cleared diverted timeout never runs: ran on resume")
    }

    /// "Timeout issued while paused starts clock now".
    func testATimeoutIssuedWhilePausedArmsTheNativeImmediatelyWithItsOwnDelay() throws {
        let shim = try loadShim()
        shim.pause()
        let before = try shim.count("h.calls.setTimeout")

        shim.run("window.setTimeout(() => {}, 5000)")

        XCTAssertFalse(
            shim.run("h.calls.setTimeout[\(before)]").isUndefined, "Timeout issued while paused starts clock now: armed"
        )
        XCTAssertEqual(
            shim.number("h.calls.setTimeout[\(before)].delay"), 5000,
            "Timeout issued while paused starts clock now: delay")
    }

    /// "Held callbacks resume in issue order".
    func testBothFamiliesFlushInIssueOrderWithinEachFamily() throws {
        let shim = try loadShim()
        shim.run(
            """
            var ran = [];
            var a = window.setTimeout(() => ran.push("tA"), 16);
            var b = window.setTimeout(() => ran.push("tB"), 16);
            window.requestAnimationFrame(() => ran.push("fX"));
            """)

        shim.pause()
        shim.run(
            """
            h.fireTimeout(a);
            h.fireTimeout(b);
            window.requestAnimationFrame(() => ran.push("fY"));
            window.requestAnimationFrame(() => ran.push("fZ"));
            """)

        shim.resumeAndDrain()

        let ran = try shim.strings("ran")
        XCTAssertEqual(
            ran.filter { $0.hasPrefix("t") }, ["tA", "tB"], "Held callbacks resume in issue order: timeouts")
        XCTAssertEqual(
            ran.filter { $0.hasPrefix("f") }, ["fX", "fY", "fZ"], "Held callbacks resume in issue order: frames")
        // No interleaving under this drain order, which is what a single
        // shared queue would produce. The order across families is the
        // engine's ("Held timeouts run before held frames", QA), not a promise of the shim.
        XCTAssertEqual(ran, ["tA", "tB", "fX", "fY", "fZ"], "Held callbacks resume in issue order: interleaved")
    }

    /// "Resume uses matching native primitive per family".
    func testEachFamilyIsCarriedByItsOwnCapturedNativePrimitive() throws {
        let shim = try loadShim()
        shim.run("var t = window.setTimeout(() => {}, 16); window.requestAnimationFrame(() => {});")
        shim.pause()
        shim.run("h.fireTimeout(t)")

        let timeoutsBefore = try shim.count("h.calls.setTimeout")
        let framesBefore = try shim.count("h.calls.requestAnimationFrame")
        shim.resume()

        XCTAssertEqual(
            try shim.count("h.calls.setTimeout"), timeoutsBefore + 1,
            "Resume uses matching native primitive per family: one hop")
        XCTAssertEqual(
            shim.number("h.calls.setTimeout[\(timeoutsBefore)].delay"), 0,
            "Resume uses matching native primitive per family: the hop's delay")
        XCTAssertEqual(
            try shim.count("h.calls.requestAnimationFrame"), framesBefore + 1,
            "Resume uses matching native primitive per family: one frame")
    }

    // MARK: - idempotence and re-pause

    /// "Second cull message is free".
    func testARepeatPauseReCancelsNothingAndDoesNotDuplicateDeliveries() throws {
        let shim = try loadShim()
        shim.run(
            """
            var ran = [];
            window.requestAnimationFrame(() => ran.push("frame"));
            var t = window.setTimeout(() => ran.push("timeout"), 16);
            """)

        shim.pause()
        shim.run("h.fireTimeout(t)")
        let cancelsAfterFirstPause = try shim.ids("h.calls.cancelAnimationFrame")

        shim.pause()
        shim.pause()
        XCTAssertEqual(
            try shim.ids("h.calls.cancelAnimationFrame"), cancelsAfterFirstPause,
            "Second cull message is free: re-cancelled")

        shim.resumeAndDrain()
        XCTAssertEqual(try shim.strings("ran"), ["timeout", "frame"], "Second cull message is free: delivered")
    }

    /// "Resume message while running does nothing".
    /// The fixture that matters is live, outstanding work when the redundant
    /// resume arrives: a resume that skips its own early-out would sweep it
    /// into a catch-up flush, delivering it early here and again when its real
    /// native timers fire.
    func testAResumeWhileRunningTouchesNothingTheCardAlreadyHasInFlight() throws {
        let shim = try loadShim()
        shim.run(
            """
            var ran = [];
            window.requestAnimationFrame(() => ran.push("frame"));
            var t = window.setTimeout(() => ran.push("timeout"), 16);
            """)

        let framesBefore = try shim.count("h.calls.requestAnimationFrame")
        let timeoutsBefore = try shim.count("h.calls.setTimeout")
        shim.resume()

        XCTAssertEqual(
            try shim.count("h.calls.requestAnimationFrame"), framesBefore,
            "Resume message while running does nothing: a catch-up frame")
        XCTAssertEqual(
            try shim.count("h.calls.setTimeout"), timeoutsBefore, "Resume message while running does nothing: a hop")
        XCTAssertEqual(try shim.strings("ran"), [], "Resume message while running does nothing: delivered early")

        shim.run("h.driveFrame(1); h.fireTimeout(t);")
        XCTAssertEqual(
            try shim.strings("ran"), ["frame", "timeout"],
            "Resume message while running does nothing: on their own native fires")

        shim.run("h.driveFrame(2); h.drainTimeouts();")
        XCTAssertEqual(
            try shim.strings("ran"), ["frame", "timeout"], "Resume message while running does nothing: delivered again")
    }

    /// "Cull during resume re-holds callbacks".
    func testARePauseDuringTheFlushReHoldsBothFamiliesAndLosesNeither() throws {
        let shim = try loadShim()
        shim.run("var ran = []; window.requestAnimationFrame(() => ran.push('frame'));")
        let nativeFrameId = try shim.id("h.calls.requestAnimationFrame[0]")
        shim.run("var t = window.setTimeout(() => ran.push('timeout'), 16);")
        shim.pause()
        shim.run("h.fireTimeout(t)")

        // Resume schedules the hop and the catch-up frame, then a cull arrives
        // before either fires.
        shim.resume()
        let catchUpId = try XCTUnwrap(shim.ids("h.calls.requestAnimationFrame").last)
        shim.pause()
        // The exact list is the assertion: the first pause retired the card's
        // own request, the second the catch-up, and nothing is cancelled twice
        // — a stale native id left behind would show up as a repeat.
        XCTAssertEqual(
            try shim.ids("h.calls.cancelAnimationFrame"), [nativeFrameId, catchUpId],
            "Cull during resume re-holds callbacks: cancelled")

        shim.run("h.drainTimeouts(); h.driveFrame(1);")
        XCTAssertEqual(try shim.strings("ran"), [], "Cull during resume re-holds callbacks: ran while paused")

        shim.resumeAndDrain(2)
        XCTAssertEqual(
            try shim.strings("ran"), ["timeout", "frame"], "Cull during resume re-holds callbacks: each exactly once")
    }

    /// "Cull before ready still holds frames".
    func testACullArrivingBeforeDOMContentLoadedStillPauses() throws {
        let shim = try loadShim()

        shim.pause()
        XCTAssertFalse(
            try shim.posted().contains { $0["tarmac"] as? String == "ready" },
            "Cull before ready still holds frames: ready was posted")

        let before = try shim.count("h.calls.requestAnimationFrame")
        shim.run("window.requestAnimationFrame(() => {})")

        XCTAssertEqual(
            try shim.count("h.calls.requestAnimationFrame"), before,
            "Cull before ready still holds frames: reached the native")
    }

    // MARK: - a delivered callback is never delivered again ("Delivered callback never runs again")

    // Every other exactly-once assertion stops after one pause → resume round
    // trip. A board culls and un-culls a card constantly as the user pans, and
    // failing to drop an entry after a natural frame, after a catch-up flush or
    // after a timeout flush leaves spent callbacks in the held queues, where
    // each later un-cull delivers them again — invisible inside one trip.

    /// "Delivered callback never runs again".
    func testAFrameDeliveredNaturallyIsNotReDeliveredByALaterRoundTrip() throws {
        let shim = try loadShim()
        shim.run("var ran = []; window.requestAnimationFrame(() => ran.push('frame')); h.driveFrame(1);")
        XCTAssertEqual(
            try shim.strings("ran"), ["frame"], "Delivered callback never runs again: delivered while running")

        shim.pause()
        shim.resumeAndDrain(2)
        XCTAssertEqual(try shim.strings("ran"), ["frame"], "Delivered callback never runs again: delivered again")
    }

    /// "Delivered callback never runs again".
    func testAFrameDeliveredByACatchUpFlushIsNotReDeliveredByTheNextOne() throws {
        let shim = try loadShim()
        shim.pause()
        shim.run("var ran = []; window.requestAnimationFrame(() => ran.push('frame'));")
        shim.resumeAndDrain(1)
        XCTAssertEqual(try shim.strings("ran"), ["frame"], "Delivered callback never runs again: flushed")

        shim.pause()
        shim.resumeAndDrain(2)
        XCTAssertEqual(try shim.strings("ran"), ["frame"], "Delivered callback never runs again: flushed again")
    }

    /// "Delivered callback never runs again".
    func testATimeoutDeliveredByAFlushIsNotReDeliveredByTheNextOne() throws {
        let shim = try loadShim()
        shim.run("var ran = []; var t = window.setTimeout(() => ran.push('timeout'), 16);")
        shim.pause()
        shim.run("h.fireTimeout(t)")
        shim.resumeAndDrain(1)
        XCTAssertEqual(try shim.strings("ran"), ["timeout"], "Delivered callback never runs again: flushed")

        shim.pause()
        shim.resumeAndDrain(2)
        XCTAssertEqual(try shim.strings("ran"), ["timeout"], "Delivered callback never runs again: flushed again")
    }

    /// "Delivered callback never runs again".
    func testSurvivesSeveralRoundTripsOverBothFamiliesAtOnce() throws {
        let shim = try loadShim()
        shim.run("var ran = []; window.requestAnimationFrame(() => ran.push('frame'));")
        let nativeFrameId = try shim.id("h.calls.requestAnimationFrame[0]")
        let timeoutsBefore = try shim.count("h.calls.setTimeout")
        shim.run("var t = window.setTimeout(() => ran.push('timeout'), 16);")
        shim.pause()
        shim.run("h.fireTimeout(t)")

        for trip in 1...4 {
            shim.resumeAndDrain(trip)
            shim.pause()
        }
        shim.resumeAndDrain(5)

        XCTAssertEqual(try shim.strings("ran"), ["timeout", "frame"], "Delivered callback never runs again: delivered")

        // Once the queues have drained, later round trips must be free: only
        // the first resume needed a catch-up frame and a hop. A resume that
        // schedules either with nothing to flush leaves a pending native
        // request behind on every un-cull — the standing charge the gate
        // exists to remove.
        XCTAssertEqual(
            try shim.count("h.calls.requestAnimationFrame"), 2,
            "Delivered callback never runs again: the card's frame and one catch-up")
        XCTAssertEqual(
            try shim.count("h.calls.setTimeout"), timeoutsBefore + 2,
            "Delivered callback never runs again: the card's timeout and one hop")

        // A spent catch-up id must not be kept and cancelled by the next pause.
        XCTAssertEqual(
            try shim.ids("h.calls.cancelAnimationFrame"), [nativeFrameId],
            "Delivered callback never runs again: cancelled")
    }

    // MARK: - a throwing flushed callback is isolated and reported ("Throwing callback in flush is isolated")

    /// "Throwing callback in flush is isolated".
    /// A throwing callback in the middle of each queue: the ones issued after
    /// it must still be delivered. The native schedulers give each callback
    /// its own task; the flush runs them in one loop, so it has to isolate
    /// them itself.
    func testDoesNotStrandTheRestOfTheQueueInEitherFamily() throws {
        let shim = try loadShim()
        shim.run(
            """
            var ran = [];
            var t1 = window.setTimeout(() => ran.push("t1"), 16);
            var t2 = window.setTimeout(() => { throw new Error("boom-timeout"); }, 16);
            var t3 = window.setTimeout(() => ran.push("t3"), 16);
            """)
        shim.pause()
        shim.run(
            """
            h.fireTimeout(t1);
            h.fireTimeout(t2);
            h.fireTimeout(t3);

            window.requestAnimationFrame(() => ran.push("f1"));
            window.requestAnimationFrame(() => { throw new Error("boom-frame"); });
            window.requestAnimationFrame(() => ran.push("f3"));
            """)

        shim.resumeAndDrain()

        XCTAssertEqual(try shim.strings("ran"), ["t1", "t3", "f1", "f3"], "Throwing callback in flush is isolated")
    }

    /// "Throwing callback in flush is isolated".
    /// The live path lets a throw reach `window.onerror` and the error relay;
    /// swallowing it here would make a card's exception vanish exactly when
    /// its callback happened to be flushed after a cull.
    func testRelaysTheExceptionRatherThanSwallowingIt() throws {
        let shim = try loadShim()
        shim.run("var t = window.setTimeout(() => { throw new Error('boom-timeout'); }, 16);")
        shim.pause()
        shim.run("h.fireTimeout(t)")
        shim.resumeAndDrain()

        XCTAssertTrue(
            try shim.hasPosted(["tarmac": "console", "level": "error", "args": ["boom-timeout"]]),
            "Throwing callback in flush is isolated")
    }

    // MARK: - the never-paused path stays transparent ("Cancel wrappers are transparent before any cull")

    /// "Cancel wrappers are transparent before any cull".
    func testForwardsEveryCancelToItsCapturedNativeAndRunsNothing() throws {
        let shim = try loadShim()
        shim.run(
            """
            var ran = [];
            var frame = window.requestAnimationFrame(() => ran.push("frame"));
            var timeout = window.setTimeout(() => ran.push("timeout"), 16);
            var interval = window.setInterval(() => ran.push("interval"), 16);
            """)

        let nativeFrame = try shim.id("h.calls.requestAnimationFrame[0]")
        let nativeTimeout = try shim.id("h.calls.setTimeout[0].id")
        let nativeInterval = try shim.id("h.calls.setInterval[0].id")

        shim.run("window.cancelAnimationFrame(frame); window.clearTimeout(timeout); window.clearInterval(interval);")

        XCTAssertEqual(
            try shim.ids("h.calls.cancelAnimationFrame"), [nativeFrame],
            "Cancel wrappers are transparent before any cull: frame")
        XCTAssertEqual(
            try shim.ids("h.calls.clearTimeout"), [nativeTimeout],
            "Cancel wrappers are transparent before any cull: timeout")
        XCTAssertEqual(
            try shim.ids("h.calls.clearInterval"), [nativeInterval],
            "Cancel wrappers are transparent before any cull: interval")

        shim.run("h.driveFrame(1); h.drainTimeouts();")
        XCTAssertEqual(try shim.strings("ran"), [], "Cancel wrappers are transparent before any cull: ran")
    }

    // MARK: - relays are never gated ("Console and escape relays work while paused")

    /// "Console and escape relays work while paused".
    func testAPausedCardCanStillReportConsoleErrorsRejectionsAndEscape() throws {
        let shim = try loadShim()
        shim.pause()

        shim.run(
            """
            window.console.log("x");
            h.fire("error", { message: "boom" });
            h.fire("unhandledrejection", { reason: "nope" });
            h.fire("keydown", { key: "Escape" });
            """)

        XCTAssertTrue(
            try shim.hasPosted(["tarmac": "console", "level": "log", "args": ["x"]]),
            "Console and escape relays work while paused: console")
        XCTAssertTrue(
            try shim.hasPosted(["tarmac": "console", "level": "error", "args": ["boom"]]),
            "Console and escape relays work while paused: error")
        XCTAssertTrue(
            try shim.hasPosted(["tarmac": "console", "level": "error", "args": ["nope"]]),
            "Console and escape relays work while paused: rejection")
        XCTAssertTrue(try shim.hasPosted(["tarmac": "escape"]), "Console and escape relays work while paused: escape")
    }

    /// "Console and escape relays work while paused".
    /// Ready is what carries the born-culled state.
    func testReadyStillPostsWhilePaused() throws {
        let shim = try loadShim()
        shim.pause()
        shim.run("h.domReady()")
        XCTAssertTrue(try shim.hasPosted(Self.ready(meta: "magnify")), "Console and escape relays work while paused")
    }

    // MARK: - hostile and malformed cull messages

    /// "Cull message from other source is ignored".
    func testACullFromAnySourceOtherThanWindowParentIsIgnored() throws {
        let shim = try loadShim()
        shim.run("h.send({ tarmac: 'cull', culled: true }, { not: 'parent' })")
        XCTAssertTrue(try shim.stillRunning(), "Cull message from other source is ignored")
    }

    /// "Malformed cull messages change nothing".
    func testAMalformedCullLeavesTheGateStateUnchangedFromEitherState() throws {
        let running = try loadShim()
        running.run("h.send({ tarmac: 'cull' })")
        XCTAssertTrue(try running.stillRunning(), "Malformed cull messages change nothing: running, no culled key")
        running.run("h.send({ tarmac: 'cull', culled: 'true' })")
        XCTAssertTrue(try running.stillRunning(), "Malformed cull messages change nothing: running, culled a string")

        // The half that carries the weight: from paused, a naive
        // `paused = !!d.culled` would un-pause on the message with no key.
        let paused = try loadShim()
        paused.pause()
        paused.run("h.send({ tarmac: 'cull' })")
        XCTAssertFalse(try paused.stillRunning(), "Malformed cull messages change nothing: paused, no culled key")
        paused.run("h.send({ tarmac: 'cull', culled: 'true' })")
        XCTAssertFalse(try paused.stillRunning(), "Malformed cull messages change nothing: paused, culled a string")
    }

    /// "Malformed cull messages change nothing".
    func testTheRelaysStillWorkAfterAMalformedCull() throws {
        let shim = try loadShim()
        shim.run("h.send({ tarmac: 'cull', culled: {} }); window.console.log('alive');")
        XCTAssertTrue(
            try shim.hasPosted(["tarmac": "console", "level": "log", "args": ["alive"]]),
            "Malformed cull messages change nothing")
    }

    // MARK: - 2609.0003 (#99): the host may post zoom more than once per document

    /// "Zoom sent before DOM ready applies on ready".
    func testAZoomArrivingBeforeDOMContentLoadedIsRetainedNotDropped() throws {
        let shim = try loadShim(meta: "magnify")

        // The negative control: without it "the zoom landed" cannot be told
        // from "the shim applies whatever arrives, whenever".
        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertTrue(
            shim.run("h.style.zoom").isUndefined,
            "2609.0003 Zoom sent before DOM ready applies on ready: applied on arrival")

        shim.run("h.domReady()")
        XCTAssertEqual(
            shim.number("h.style.zoom"), 3, "2609.0003 Zoom sent before DOM ready applies on ready: retained")
        XCTAssertTrue(
            try shim.hasPosted(Self.ready(meta: "magnify")),
            "2609.0003 Zoom sent before DOM ready applies on ready: ready")
    }

    /// "Every post-ready zoom is applied".
    /// The premise of the #99 fix: the host re-posts the same constant on a
    /// self-reload, so a shim that ignored everything after the first zoom
    /// would leave the reloaded document unzoomed. The values are distinct
    /// because re-sending 3 and reading 3 cannot tell "applied again" from
    /// "ignored". That a repeat causes no relayout is not shown here — the
    /// stand-in `style` has no layout behind it (2609.0003 "Forged ready logs no second mode line", QA).
    func test2609_0003S9EveryPostReadyZoomIsAppliedNotJustTheFirst() throws {
        let shim = try loadShim(meta: "magnify")
        shim.run("h.domReady()")
        let postedAfterReady = try shim.posted().count

        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "2609.0003 Every post-ready zoom is applied: first")
        shim.run("h.send({ tarmac: 'zoom', z: 4 })")
        XCTAssertEqual(shim.number("h.style.zoom"), 4, "2609.0003 Every post-ready zoom is applied: second")
        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "2609.0003 Every post-ready zoom is applied: third")

        XCTAssertEqual(
            try shim.posted().count, postedAfterReady, "2609.0003 Every post-ready zoom is applied: a zoom was answered"
        )
    }

    /// "Zoom from a foreign source is ignored".
    func testARepeatZoomFromAnySourceButWindowParentIsIgnored() throws {
        let shim = try loadShim(meta: "magnify")
        shim.run("h.domReady(); h.send({ tarmac: 'zoom', z: 3 });")

        shim.run("h.send({ tarmac: 'zoom', z: 40 }, { nested: 'iframe' })")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "2609.0003 Zoom from a foreign source is ignored")
    }

    // MARK: - the wheel is not a message (2610.0002 "Shim no longer relays scroll messages")

    /// "Shim no longer relays scroll messages".
    /// The web view takes the wheel itself, so a `scroll` from the host is one
    /// more message the shim does not know: it scrolls nothing, and the
    /// listener is still there for the next one.
    func testAScrollFromTheHostScrollsNothing() throws {
        let shim = try loadShim()
        shim.run("var scrolled = []; window.scrollBy = (dx, dy) => scrolled.push([dx, dy]);")

        shim.run("h.send({ tarmac: 'scroll', dx: 4, dy: -9 })")
        XCTAssertEqual(try shim.count("scrolled"), 0, "2610.0002 Shim no longer relays scroll messages: scrollBy")

        shim.pause()
        shim.run("window.requestAnimationFrame(() => {});")
        XCTAssertEqual(
            try shim.ids("h.pendingFrameIds()"), [],
            "2610.0002 Shim no longer relays scroll messages: a cull after it still pauses")
    }

    // MARK: - the root's scroll position is reported (2610.0003)

    /// A shim loaded into a window whose root is scrolled to 120 of 4800, 840
    /// of it showing: set once the shim has loaded, so what it posts is read
    /// as it posts.
    private func loadScrolledShim(omitting native: String? = nil) throws -> Shim {
        let shim = try loadShim(omitting: native)
        shim.run("window.scrollY = 120; document.scrollingElement = { clientHeight: 840, scrollHeight: 4800 };")
        return shim
    }

    private func reports(_ shim: Shim) throws -> [NSDictionary] {
        try shim.posted().filter { $0["tarmac"] as? String == "scrolled" }
    }

    private static let triggers = ["h.scroll()", "h.fire('resize', {})", "h.observers[0].callback([])"]

    /// "Shim posts metrics on scroll and resize".
    func testEachTriggerPostsWhereTheRootIsScrolledTo() throws {
        let shim = try loadScrolledShim()
        let report: NSDictionary = ["tarmac": "scrolled", "offset": 120, "visible": 840, "total": 4800]

        shim.run("h.scroll()")
        XCTAssertEqual(try reports(shim), [report], "a root scroll")
        shim.run("h.scroll()")
        XCTAssertEqual(try reports(shim), [report, report], "a second one, the same numbers")

        shim.run("h.fire('resize', {})")
        XCTAssertEqual(try reports(shim).count, 3, "a resize")

        XCTAssertEqual(try shim.count("h.observers"), 1)
        XCTAssertEqual(shim.flag("h.observers[0].observed[0] === document.documentElement"), true)
        shim.run("h.observers[0].callback([])")
        XCTAssertEqual(try reports(shim).count, 4, "a size observation")
        XCTAssertEqual(try reports(shim).last, report)

        shim.run("window.scrollY = 360; h.scroll();")
        XCTAssertEqual(try reports(shim).last?["offset"] as? Int, 360, "read as it posts")
    }

    /// "Shim hides the root scrollbar".
    func testTheRootsOwnScrollbarIsHiddenByReady() throws {
        let shim = try loadShim()
        shim.run("h.domReady()")
        XCTAssertEqual(shim.run("h.style.scrollbarWidth").toString(), "none")
    }

    /// "Element scroll posts nothing".
    func testANestedElementsScrollPostsNothing() throws {
        let shim = try loadScrolledShim()
        shim.run("h.scroll({ id: 'inner' })")
        XCTAssertEqual(try reports(shim), [])
    }

    /// "Report costs no scheduling".
    /// A culled card must leave no native frame pending (2609.0002): a report
    /// asks for none, and for no timer either, paused or not.
    func testAReportCostsNoScheduling() throws {
        let shim = try loadScrolledShim()
        func natives() throws -> [Int] {
            try ["requestAnimationFrame", "setTimeout", "setInterval"].map { try shim.count("h.calls.\($0)") }
        }
        let live = try natives()
        for trigger in Self.triggers { shim.run(trigger) }
        XCTAssertEqual(try natives(), live, "live")
        XCTAssertEqual(try reports(shim).count, 3)

        shim.pause()
        let culled = try natives()
        for trigger in Self.triggers { shim.run(trigger) }
        XCTAssertEqual(try natives(), culled, "culled")
        XCTAssertEqual(try reports(shim).count, 6, "a culled card still reports")
    }

    // MARK: - the host scrolls the root to a position (2610.0004)

    /// A shim in a window scrolled 12 across, which records what `scrollTo`
    /// is asked for as "left top behavior".
    private func loadScrollableShim() throws -> Shim {
        let shim = try loadShim()
        shim.run(
            """
            var scrolledTo = []; window.scrollX = 12;
            window.scrollTo = (to) => scrolledTo.push([to.left, to.top, to.behavior].join(' '));
            """)
        return shim
    }

    /// "Shim scrolls the window on scrollTo".
    func testAScrollToFromTheHostScrollsTheRootAtOnce() throws {
        let shim = try loadScrollableShim()
        shim.run("h.send({ tarmac: 'scrollTo', y: 300 })")
        XCTAssertEqual(try shim.strings("scrolledTo"), ["12 300 instant"])

        shim.run("h.send({ tarmac: 'scrollTo', y: 0 })")
        XCTAssertEqual(try shim.strings("scrolledTo"), ["12 300 instant", "12 0 instant"])
    }

    /// "Shim refuses a bad scrollTo message".
    func testAScrollToTheShimCannotTrustScrollsNothing() throws {
        let shim = try loadScrollableShim()
        shim.run("h.send({ tarmac: 'scrollTo' })")
        for y in ["'300'", "true", "null", "NaN", "Infinity"] {
            shim.run("h.send({ tarmac: 'scrollTo', y: \(y) })")
            XCTAssertEqual(try shim.count("scrolledTo"), 0, "y: \(y)")
        }
        shim.run("h.send({ tarmac: 'scrollTo', y: 300 }, {})")
        XCTAssertEqual(try shim.count("scrolledTo"), 0, "not from the parent")
        shim.run("h.send({ tarmac: 'scroll', y: 300 })")
        XCTAssertEqual(try shim.count("scrolledTo"), 0, "the shim knows no scroll")

        shim.run("h.send({ tarmac: 'scrollTo', y: 300 })")
        XCTAssertEqual(try shim.count("scrolledTo"), 1, "the window does record one it trusts")
    }

    /// "ScrollTo costs no frame or timer when culled".
    func testAScrollToCostsNoScheduling() throws {
        let shim = try loadScrollableShim()
        func natives() throws -> [Int] {
            try ["requestAnimationFrame", "setTimeout", "setInterval"].map { try shim.count("h.calls.\($0)") }
        }
        let live = try natives()
        shim.run("h.send({ tarmac: 'scrollTo', y: 300 })")
        XCTAssertEqual(try natives(), live, "live")

        shim.pause()
        let culled = try natives()
        shim.run("h.send({ tarmac: 'scrollTo', y: 600 })")
        XCTAssertEqual(try natives(), culled, "culled")
        XCTAssertEqual(
            try shim.strings("scrolledTo"), ["12 300 instant", "12 600 instant"], "a culled card still scrolls")
    }

    /// 2610.0003 "Shim loads without ResizeObserver".
    func testAWindowWithNoResizeObserverStillReports() throws {
        let shim = try loadScrolledShim(omitting: "ResizeObserver")
        shim.run("h.scroll(); h.fire('resize', {});")
        XCTAssertEqual(try reports(shim).count, 2)
    }

    /// 2610.0003 "Shim loads without ResizeObserver".
    /// Before the body exists a quirks-mode document has no scrolling
    /// element. A throw here would land in the card's own console.
    func test2610S25ADocumentWithNoScrollingElementPostsNothing() throws {
        for missing in ["document.scrollingElement = null;", "delete document.scrollingElement;"] {
            let shim = try loadScrolledShim()
            shim.run(missing)
            for trigger in Self.triggers {
                XCTAssertNil(shim.thrown(trigger), "\(missing) \(trigger)")
            }
            XCTAssertEqual(try reports(shim), [], missing)
        }
    }

    // MARK: - a document follows the appearance unless it states a scheme (2610.0007)

    // What the engine does with the meta is QA (2610.0007):
    // JavaScriptCore has no CSS.

    private static let headElements =
        "document.head.children.map((el) => [el.localName, el.name, el.content].join(' '))"
    private static let defaultScheme = "meta color-scheme light dark"

    /// A shim in a document with a head, and `scheme`: the head's first child
    /// once the shim has loaded.
    private func loadShimInADocumentWithAHead() throws -> Shim {
        let shim = try loadShim(head: true)
        shim.run("var scheme = document.head.children[0];")
        return shim
    }

    /// "Shim adds a color-scheme meta first".
    func testTheShimsFirstActIsOneDefaultSchemeMetaInTheHead() throws {
        let shim = try loadShim(head: true)

        XCTAssertEqual(
            try shim.strings(Self.headElements), [Self.defaultScheme],
            "2610.0007 Shim adds a color-scheme meta first: the head")
        XCTAssertEqual(
            try shim.strings("document.head.before"), [],
            "2610.0007 Shim adds a color-scheme meta first: what the shim did first")
    }

    /// "Shim yields to the page's own meta".
    /// The watch is on the root with its subtree: a meta is a child of the
    /// head, not of the root.
    func testAnElementThatIsNoSchemeMetaLeavesTheDefaultInPlace() throws {
        let shim = try loadShimInADocumentWithAHead()
        XCTAssertEqual(try shim.count("h.watchers"), 1, "2610.0007 Shim yields to the page's own meta: one observer")
        XCTAssertEqual(shim.flag("h.watchers[0].observed[0].target === document.documentElement"), true, "the root")
        XCTAssertEqual(shim.flag("h.watchers[0].observed[0].options.childList"), true, "childList")
        XCTAssertEqual(shim.flag("h.watchers[0].observed[0].options.subtree"), true, "subtree")

        shim.run(
            """
            h.parse("meta", { charset: "utf-8" });
            h.parse("title");
            h.parse("meta", { name: "viewport", content: "width=device-width" });
            h.parse("meta", { name: "tarmac-zoom", content: "reveal" });
            h.parse("style");
            """)

        XCTAssertEqual(
            shim.flag("document.head.children[0] === scheme"), true,
            "2610.0007 Shim yields to the page's own meta: the default")
        XCTAssertEqual(
            try shim.count("document.head.children"), 6, "2610.0007 Shim yields to the page's own meta: the head")
        XCTAssertEqual(
            shim.flag("h.watchers[0].connected"), true, "2610.0007 Shim yields to the page's own meta: still watching")

        shim.run("h.parse('meta', { name: 'color-scheme', content: 'dark' })")
        XCTAssertEqual(
            shim.flag("document.head.children.includes(scheme)"), false,
            "2610.0007 Shim yields to the page's own meta: then the author's")
    }

    /// "Shim yields to the page's own meta".
    func testAnAuthorsSchemeMetaInAnyLetterCaseRemovesTheDefaultAndEndsTheWatch() throws {
        for name in ["color-scheme", "Color-Scheme", "COLOR-SCHEME"] {
            let shim = try loadShimInADocumentWithAHead()
            XCTAssertEqual(
                shim.flag("h.watchers[0].connected"), true,
                "2610.0007 Shim yields to the page's own meta: watching, \(name)")

            shim.run("h.parse('meta', { name: '\(name)', content: 'light' })")

            XCTAssertEqual(
                try shim.strings(Self.headElements), ["meta \(name) light"],
                "2610.0007 Shim yields to the page's own meta: the head")
            XCTAssertEqual(
                try shim.strings("document.head.changes"), ["append meta", "parse meta", "remove meta"],
                "2610.0007 Shim yields to the page's own meta: \(name)"
            )
            XCTAssertEqual(
                shim.flag("h.watchers[0].connected"), false,
                "2610.0007 Shim yields to the page's own meta: still watching, \(name)")
        }
    }

    /// "Shim keeps its meta after load".
    /// The last part is the contract's "a meta that an author's script adds
    /// after the document is parsed is not a statement the default gives way
    /// to": an observer that is still connected would take the default away.
    func testDOMContentLoadedEndsTheWatchAndKeepsTheDefault() throws {
        let shim = try loadShimInADocumentWithAHead()
        XCTAssertEqual(
            shim.flag("h.watchers[0].connected"), true,
            "2610.0007 Shim keeps its meta after load: watching while the document is parsed")

        shim.run("h.domReady()")
        XCTAssertEqual(
            shim.flag("h.watchers[0].connected"), false, "2610.0007 Shim keeps its meta after load: still watching")
        XCTAssertEqual(
            try shim.strings(Self.headElements), [Self.defaultScheme],
            "2610.0007 Shim keeps its meta after load: the default")

        shim.run("h.parse('meta', { name: 'color-scheme', content: 'light' })")
        XCTAssertEqual(
            shim.flag("document.head.children[0] === scheme"), true,
            "2610.0007 Shim keeps its meta after load: a late meta")
    }

    /// "Shim loads on the old stand-in window".
    /// The document every test outside this section runs in. A throw at load
    /// fails the test through the context's exception handler.
    func testADocumentWithNoHeadLoadsTheShimAsItDidBefore() throws {
        let shim = try loadShim()
        XCTAssertEqual(
            try shim.strings("[typeof document.head, typeof document.createElement, typeof MutationObserver]"),
            ["undefined", "undefined", "undefined"],
            "2610.0007 Shim loads on the old stand-in window: the stand-in of today"
        )

        shim.run("h.domReady()")
        XCTAssertTrue(
            try shim.hasPosted(Self.ready(meta: "magnify")),
            "2610.0007 Shim loads on the old stand-in window: the rest of the shim")
    }

    /// "Shim loads on the old stand-in window".
    func testAWindowWithNoMutationObserverKeepsTheDefaultAndLoads() throws {
        let shim = try loadShim(omitting: "MutationObserver", head: true)
        XCTAssertEqual(
            try shim.strings(Self.headElements), [Self.defaultScheme],
            "2610.0007 Shim loads on the old stand-in window: the head")

        shim.run("h.domReady()")
        XCTAssertTrue(
            try shim.hasPosted(Self.ready(meta: "magnify")),
            "2610.0007 Shim loads on the old stand-in window: the rest of the shim")
    }

    // MARK: - the user's fonts as CSS properties (2610.0010)

    private static let fonts = CardFontVariables(interfaceFamily: "Menlo", documentFamily: "Georgia", documentSize: 16)
    private static let otherFonts = CardFontVariables(interfaceFamily: nil, documentFamily: nil, documentSize: 20)

    /// The properties of the one `:root` rule of the font sheet: the adopted
    /// sheet whose first rule is `:root`.
    private func declared(_ shim: Shim) throws -> [String: String] {
        let found =
            "document.adoptedStyleSheets.find((s) => s.cssRules && s.cssRules[0] && s.cssRules[0].selectorText === ':root')"
        let json = shim.run("JSON.stringify(\(found).cssRules[0].style.values)")
        let text = try XCTUnwrap(json.isString ? json.toString() : nil, "no rule is declared")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
    }

    private func vars(_ fonts: CardFontVariables) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fonts.json.utf8)) as? [String: String])
    }

    private func sendFonts(_ shim: Shim, _ vars: String) {
        shim.run("h.send({ tarmac: 'fonts', vars: \(vars) })")
    }

    /// "Shipped shim holds the marker once".
    func testTheShimHoldsTheMarkerOnceAsAComment() throws {
        let shim = try source()
        XCTAssertEqual(
            shim.components(separatedBy: CardFontVariables.marker).count, 2, "Shipped shim holds the marker once: once")
        XCTAssertTrue(
            shim.contains("[\(CardFontVariables.marker)][0]"), "Shipped shim holds the marker once: alone in the array")
        XCTAssertTrue(CardFontVariables.marker.hasPrefix("/*"), "Shipped shim holds the marker once: a comment")
    }

    /// "Filled shim declares one root rule early".
    func testAFilledShimDeclaresTheThreePropertiesBeforeTheDocumentIsParsed() throws {
        let shim = try loadShim(fonts: Self.fonts)
        XCTAssertEqual(
            try shim.count("document.adoptedStyleSheets"), 2,
            "Filled shim declares one root rule early: the media sheet and the font sheet")
        XCTAssertEqual(
            try shim.count("document.adoptedStyleSheets[1].cssRules"), 1,
            "Filled shim declares one root rule early: one rule")
        XCTAssertEqual(shim.run("document.adoptedStyleSheets[1].cssRules[0].selectorText").toString(), ":root")
        XCTAssertEqual(try declared(shim), try vars(Self.fonts))
    }

    /// "Shim sets no style or attribute on root".
    func testTheFontsGoToTheSheetAndNeverToTheRootsStyleOrAttributes() throws {
        let shim = try loadShim(head: true, fonts: Self.fonts)
        sendFonts(shim, Self.otherFonts.json)

        XCTAssertEqual(
            try declared(shim), try vars(Self.otherFonts),
            "Shim sets no style or attribute on root: the rule holds the message")
        XCTAssertEqual(
            try shim.strings("Object.keys(h.style)"), ["setProperty"],
            "Shim sets no style or attribute on root: the root's style holds no value")
        XCTAssertEqual(
            try shim.count("h.rootWrites"), 0, "Shim sets no style or attribute on root: no write on the root")
        XCTAssertEqual(
            try shim.strings(Self.headElements), [Self.defaultScheme],
            "Shim sets no style or attribute on root: the head")
    }

    /// "Raw shim declares nothing".
    func testARawShimDeclaresNothing() throws {
        let shim = try loadShim(head: true)
        XCTAssertEqual(try shim.count("h.sheets"), 1, "Raw shim declares nothing: the media sheet only is made")
        XCTAssertEqual(
            try shim.count("document.adoptedStyleSheets"), 1,
            "Raw shim declares nothing: the media sheet only is adopted")
        XCTAssertEqual(
            shim.flag("h.sheets.some((s) => s.cssRules.some((r) => r.selectorText === ':root'))"), false,
            "Raw shim declares nothing: no font sheet is made")
        shim.run("h.domReady()")
        XCTAssertTrue(
            try shim.hasPosted(Self.ready(meta: "magnify")), "Raw shim declares nothing: the rest of the shim")
    }

    /// "Shim without stylesheet support throws nothing".
    func testAWindowWithNoConstructedStylesheetsLoadsAndStillWorks() throws {
        let shim = try loadShim(omitting: "CSSStyleSheet", fonts: Self.fonts)
        XCTAssertNil(
            shim.thrown("h.send({ tarmac: 'fonts', vars: { '--tarmac-prose-size': '20px' } })"),
            "Shim without stylesheet support throws nothing: a message")
        shim.run("h.domReady()")
        XCTAssertTrue(
            try shim.hasPosted(Self.ready(meta: "magnify")), "Shim without stylesheet support throws nothing: ready")
        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "Shim without stylesheet support throws nothing: zoom")
        shim.pause()
        XCTAssertFalse(try shim.stillRunning(), "Shim without stylesheet support throws nothing: cull")
    }

    /// "Fonts block runs before the first listener".
    func testTheFontsBlockRunsAfterTheStartedPostAndBeforeTheFirstListener() throws {
        let shim = try loadShim(head: true, fonts: Self.fonts)
        XCTAssertEqual(
            try shim.count("h.sheets"), 2,
            "Fonts block runs before the first listener: the media sheet and the font sheet")
        XCTAssertEqual(
            try shim.strings(Self.headElements), [Self.defaultScheme],
            "Fonts block runs before the first listener: the block added no head element")
        XCTAssertEqual(try shim.posted().count, 1, "Fonts block runs before the first listener: one message by now")
        XCTAssertEqual(
            shim.run("JSON.stringify(h.sheets[1].atConstruction.posted)").toString(),
            #"[{"tarmac":"started","source":"tarmac-card://doc/card.html?v=1"}]"#,
            "Fonts block runs before the first listener: after started"
        )
        XCTAssertEqual(
            try shim.strings("h.sheets[1].atConstruction.listeners"), [],
            "Fonts block runs before the first listener: before the first listener")
    }

    /// "Fonts message updates the rule values".
    func testAMessageSetsTheNewValuesAndALaterOneReplacesThem() throws {
        let shim = try loadShim(fonts: Self.fonts)
        sendFonts(shim, "{ '--tarmac-prose-size': '20px' }")
        var expected = try vars(Self.fonts)
        expected["--tarmac-prose-size"] = "20px"
        XCTAssertEqual(try declared(shim), expected, "Fonts message updates the rule values: one property named")

        sendFonts(shim, Self.otherFonts.json)
        XCTAssertEqual(
            try declared(shim), try vars(Self.otherFonts), "Fonts message updates the rule values: all three named")
        XCTAssertEqual(
            try shim.count("document.adoptedStyleSheets"), 2,
            "Fonts message updates the rule values: still one font sheet")
    }

    /// "Bad fonts messages are ignored".
    func testAMessageWithNoObjectOfVarsChangesNothing() throws {
        let shim = try loadShim(fonts: Self.fonts)
        for bad in ["undefined", "null", "['--tarmac-prose-size']", "'--tarmac-prose-size'", "7"] {
            sendFonts(shim, bad)
            XCTAssertEqual(try declared(shim), try vars(Self.fonts), bad)
        }
    }

    /// "Bad fonts messages are ignored".
    func testAnEntryIsSkippedUnlessItsNameStartsWithTarmacAndItsValueIsAString() throws {
        let shim = try loadShim(fonts: Self.fonts)
        sendFonts(
            shim,
            """
            { 'color': 'red', '--other': 'x', '--tarmac-prose-size': 20, '--tarmac-mono-font': null,
              '--tarmac-prose-font': 'serif' }
            """)
        var expected = try vars(Self.fonts)
        expected["--tarmac-prose-font"] = "serif"
        XCTAssertEqual(try declared(shim), expected)
    }

    /// "Bad fonts messages are ignored".
    func testAMessageNotFromTheParentIsIgnored() throws {
        let shim = try loadShim(fonts: Self.fonts)
        shim.run("h.send({ tarmac: 'fonts', vars: { '--tarmac-prose-size': '99px' } }, {})")
        XCTAssertEqual(try declared(shim), try vars(Self.fonts))

        let raw = try loadShim()
        raw.run("h.send({ tarmac: 'fonts', vars: { '--tarmac-prose-size': '99px' } }, {})")
        XCTAssertEqual(try raw.count("h.sheets"), 1, "no sheet but the media sheet is made for it")
    }

    /// "Fonts message before load applies at once".
    func testAMessageIsAppliedAtOnceAndTheLoadChangesNothingAfterIt() throws {
        for (shim, pageSheets) in [(try loadShim(fonts: Self.fonts), 0), (try loadShim(), 1)] {
            if pageSheets > 0 { shim.run("document.adoptedStyleSheets = [{ page: true }]") }
            sendFonts(shim, Self.otherFonts.json)
            XCTAssertEqual(
                try declared(shim), try vars(Self.otherFonts),
                "Fonts message before load applies at once: before DOMContentLoaded")

            shim.run("h.domReady()")
            XCTAssertEqual(
                try declared(shim), try vars(Self.otherFonts), "Fonts message before load applies at once: after it")
            XCTAssertEqual(
                try shim.count("document.adoptedStyleSheets"), 2,
                "Fonts message before load applies at once: the sheets")
            XCTAssertEqual(
                shim.flag("document.adoptedStyleSheets[0].page === true"), pageSheets > 0,
                "Fonts message before load applies at once: the page's own sheet first")
        }
    }

    /// "Fonts message adds no timer and keeps pause".
    func testAMessageSchedulesNothingLeavesTheZoomAloneAndIsAppliedWhilePaused() throws {
        let shim = try loadShim(fonts: Self.fonts)
        let scheduled = "JSON.stringify([h.calls, h.pendingFrameIds(), h.pendingTimeoutIds()])"
        let before = shim.run(scheduled).toString()
        sendFonts(shim, Self.otherFonts.json)
        XCTAssertEqual(shim.run(scheduled).toString(), before)
        XCTAssertEqual(shim.flag("'zoom' in h.style"), false, "Fonts message adds no timer and keeps pause: no zoom")
        XCTAssertEqual(
            try declared(shim), try vars(Self.otherFonts), "Fonts message adds no timer and keeps pause: live")

        shim.pause()
        sendFonts(shim, "{ '--tarmac-prose-size': '18px' }")
        XCTAssertEqual(
            try declared(shim)["--tarmac-prose-size"], "18px", "Fonts message adds no timer and keeps pause: paused")
        XCTAssertFalse(try shim.stillRunning(), "Fonts message adds no timer and keeps pause: still paused")
    }

    // MARK: - the document tells its host that it has started (#213)

    /// The app keeps the card's web view out of sight until the host page
    /// says `shown`, and this message is what the host page waits for: it is
    /// posted as the shim loads, before any author script runs, and
    /// waits for nothing. In the document every older test runs in, the default
    /// scheme's block throws, and the message is posted all the same. It names
    /// the document's address: the host page can have given the frame a newer
    /// source by the time it hears this.
    func testTheShimTellsItsParentThatTheDocumentHasStartedAsItLoads() throws {
        for head in [false, true] {
            let shim = try loadShim(head: head)
            XCTAssertEqual(
                try shim.posted(), [["tarmac": "started", "source": "tarmac-card://doc/card.html?v=1"]], "head: \(head)"
            )
        }
    }

    func testTheStartIsPostedOnceForADocument() throws {
        let shim = try loadShim(head: true)

        shim.run("h.parse('meta', { name: 'color-scheme', content: 'light' }); h.domReady(); h.scroll()")

        XCTAssertEqual(try shim.posted().filter { $0["tarmac"] as? String == "started" }.count, 1)
    }

    // MARK: - the never-paused path, beyond the cancels

    func testALiveFrameCallbackReceivesTheNativeTimestamp() throws {
        let shim = try loadShim()
        shim.run("var seen = []; window.requestAnimationFrame((ts) => seen.push(ts)); h.driveFrame(321);")
        XCTAssertEqual(shim.number("seen[0]"), 321)
    }

    func testALiveTimeoutKeepsItsExtraArguments() throws {
        let shim = try loadShim()
        shim.run(
            "var seen = []; var id = window.setTimeout((...args) => seen.push(args), 16, 'a', 7); h.fireTimeout(id);")
        XCTAssertEqual(shim.run("seen").toArray() as NSArray?, [["a", 7]])
    }

    func testAnIntervalKeepsItsDelayAndItsExtraArguments() throws {
        let shim = try loadShim()
        shim.run("var seen = []; window.setInterval((...args) => seen.push(args), 250, 'a', 7);")
        XCTAssertEqual(shim.number("h.calls.setInterval[0].delay"), 250, "delay")

        shim.run("h.tickInterval(h.calls.setInterval[0].id)")
        XCTAssertEqual(shim.run("seen").toArray() as NSArray?, [["a", 7]], "arguments")
    }

    func testATimeoutIssuedWhilePausedRunsWhenItFiresAfterTheResume() throws {
        let shim = try loadShim()
        shim.pause()
        shim.run("var runs = 0; var id = window.setTimeout(() => { runs++; }, 16);")
        shim.resumeAndDrain()
        XCTAssertEqual(shim.number("runs"), 1)
    }

    func testCancellingASpentOrHeldFrameIdReachesNoNative() throws {
        let shim = try loadShim()
        shim.run(
            "var spent = window.requestAnimationFrame(() => {}); h.driveFrame(1); window.cancelAnimationFrame(spent);")
        XCTAssertEqual(try shim.ids("h.calls.cancelAnimationFrame"), [], "a spent id")

        shim.pause()
        shim.run("var held = window.requestAnimationFrame(() => {}); window.cancelAnimationFrame(held);")
        XCTAssertEqual(try shim.count("h.calls.cancelAnimationFrame"), 0, "a held id")
    }

    func testAClearBetweenTheResumeAndItsFlushStillDropsTheCallback() throws {
        let shim = try loadShim()
        shim.run("var ran = []; var t = window.setTimeout(() => ran.push('timeout'), 16);")
        shim.pause()
        shim.run("h.fireTimeout(t); var f = window.requestAnimationFrame(() => ran.push('frame'));")
        shim.resume()
        shim.run("window.clearTimeout(t); window.cancelAnimationFrame(f); h.drainTimeouts(); h.driveFrame(1);")
        XCTAssertEqual(try shim.strings("ran"), [])
    }

    func testReadyIsPostedOncePerDocumentAndAnUnknownMessageLeavesTheZoomAlone() throws {
        let shim = try loadShim()
        shim.run("h.domReady(); h.domReady(); h.send({ tarmac: 'zoom', z: 3 });")
        shim.pause()
        shim.resume()
        shim.run("h.send({ tarmac: 'later-protocol', z: 9 })")

        XCTAssertEqual(try shim.posted().filter { $0["tarmac"] as? String == "ready" }.count, 1, "ready")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "zoom")
    }

    /// "Malformed cull messages change nothing".
    /// The host pins a real boolean (`CardHostMessageTests`); this is the shim's half.
    func testANumberIsNoBooleanToTheGateFromEitherState() throws {
        let running = try loadShim()
        running.run("h.send({ tarmac: 'cull', culled: 1 })")
        XCTAssertTrue(try running.stillRunning(), "Malformed cull messages change nothing: running, culled 1")

        let paused = try loadShim()
        paused.pause()
        paused.run("h.send({ tarmac: 'cull', culled: 0 })")
        XCTAssertFalse(try paused.stillRunning(), "Malformed cull messages change nothing: paused, culled 0")
    }

    // MARK: - the data file (2611.0002)

    private let address = "tarmac-card://doc/card.html?v=1"

    private func readies(_ shim: Shim) throws -> [NSDictionary] {
        try shim.posted().filter { $0["tarmac"] as? String == "ready" }
    }

    private func nameErrors(_ shim: Shim) throws -> [NSDictionary] {
        try shim.posted().filter {
            $0["tarmac"] as? String == "console" && $0["level"] as? String == "error"
                && "\($0["args"] ?? "")".contains("tarmac-data")
        }
    }

    /// "Data meta name reaches ready message".
    func testReadyNamesTheDataFileAndTheDocumentsAddress() throws {
        let shim = try loadShim(meta: "magnify", data: "stats.json")
        shim.run("h.domReady()")
        XCTAssertEqual(
            try readies(shim),
            [["tarmac": "ready", "meta": "magnify", "data": "stats.json", "source": address]]
        )
        XCTAssertEqual(try shim.posted().first?["source"] as? String, address, "the source of its started word")
    }

    /// "Missing or empty data meta gives null".
    func testReadyNamesNoFileWithNoMetaOrAnEmptyOne() throws {
        for data in [nil, ""] as [String?] {
            let shim = try loadShim(meta: nil, data: data)
            shim.run("h.domReady()")
            XCTAssertEqual(
                try readies(shim), [["tarmac": "ready", "meta": NSNull(), "data": NSNull(), "source": address]],
                "\(data.debugDescription)"
            )
        }
    }

    /// "Data name making ready over limit is refused".
    /// The shim's bound is the host page's, which is the app's line cap
    /// (`CardHostScriptTests`).
    func testTheShimMeasuresAgainstTheLineCapTheAppKeeps() throws {
        let regex = try NSRegularExpression(pattern: #"var messageCap = (\d+);"#)
        let text = try source()
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        XCTAssertEqual(Int(text[try XCTUnwrap(Range(match.range(at: 1), in: text))]), CardConsole.lineCap)
    }

    /// "Data name making ready over limit is refused".
    /// The host page carries a message of at most `CardConsole.lineCap`
    /// characters of JSON. The name is measured as JSON writes it, and a page
    /// that took `console.error` for itself does not keep the line from the app.
    func testANameThatDoesNotFitIsLeftOutAndSaidSo() throws {
        let fill = "(n, unit) => unit.repeat(n)"
        let room = "\(CardConsole.lineCap) - JSON.stringify({ tarmac: 'ready', meta: null, data: '' }).length"
        for (unit, width) in [("x", 1), ("\\\"", 2)] {
            let probe = try loadShim(meta: nil)
            let free = try XCTUnwrap(probe.number(room).flatMap { Int(exactly: $0) })
            XCTAssertEqual(free % width, 0, "the bound is reached exactly")
            let fits = try XCTUnwrap(probe.run("(\(fill))(\(free / width), '\(unit)')").toString())
            let over = try XCTUnwrap(probe.run("(\(fill))(\(free / width + 1), '\(unit)')").toString())

            let fitting = try loadShim(meta: nil, data: fits)
            fitting.run("h.domReady()")
            XCTAssertEqual(try readies(fitting).first?["data"] as? String, fits, "unit \(unit)")
            XCTAssertEqual(
                fitting.number("JSON.stringify({ tarmac: 'ready', meta: null, data: h.posted.at(-1).data }).length"),
                Double(CardConsole.lineCap)
            )
            XCTAssertEqual(try nameErrors(fitting), [], "unit \(unit)")

            let long = try loadShim(meta: nil, data: over)
            long.run("window.console.error = function () {}; h.domReady()")
            XCTAssertEqual(
                try readies(long), [["tarmac": "ready", "meta": NSNull(), "data": NSNull(), "source": address]],
                "unit \(unit)"
            )
            XCTAssertEqual(try nameErrors(long).count, 1, "unit \(unit)")
        }
    }

    /// "Data name making ready over limit is refused".
    /// A `ready` that its zoom meta alone takes over the bound is dropped by
    /// the host page whatever it names, as it is today: the name is kept, and
    /// the console is told nothing of it.
    func testAReadyTooLongWithoutTheNameKeepsItAndSaysNothing() throws {
        let shim = try loadShim(meta: String(repeating: "x", count: CardConsole.lineCap), data: "stats.json")
        shim.run("h.domReady()")
        XCTAssertEqual(try readies(shim).first?["data"] as? String, "stats.json")
        XCTAssertEqual(try nameErrors(shim), [])
    }

    /// "Data is undefined before any delivery".
    func testBeforeAnyDataTheGlobalIsAnObjectWithNoData() throws {
        let shim = try loadShim()
        XCTAssertEqual(shim.run("typeof window.tarmac").toString(), "object")
        XCTAssertEqual(shim.flag("window.tarmac !== null && window.tarmac.data === undefined"), true)
    }

    private func listen(_ shim: Shim) {
        shim.run("var heard = []; window.addEventListener('tarmac:data', (e) => heard.push(e));")
    }

    private func deliver(_ shim: Shim, _ text: String, from source: String = "parent") {
        shim.run("h.send({ tarmac: 'data', text: \(text) }, \(source))")
    }

    private func json(_ shim: Shim, _ expression: String) -> String? {
        let value = shim.run("JSON.stringify(\(expression))")
        return value.isString ? value.toString() : nil
    }

    /// "Delivery fires event with parsed detail".
    func testADeliveryIsParsedKeptAndDispatched() throws {
        let shim = try loadShim()
        listen(shim)
        deliver(shim, #"'{"n":1}'"#)
        XCTAssertEqual(shim.number("heard.length"), 1)
        XCTAssertEqual(shim.run("heard[0].type").toString(), "tarmac:data")
        XCTAssertEqual(json(shim, "heard[0].detail"), #"{"n":1}"#)
        XCTAssertEqual(shim.flag("window.tarmac.data === heard[0].detail"), true)
    }

    /// "Second delivery replaces the first".
    func testEachDeliveryIsDispatchedInOrderAndTheLastIsKept() throws {
        let shim = try loadShim()
        listen(shim)
        deliver(shim, #"'{"n":1}'"#)
        deliver(shim, "'[2]'")
        XCTAssertEqual(json(shim, "heard.map((e) => e.detail)"), #"[{"n":1},[2]]"#)
        XCTAssertEqual(json(shim, "window.tarmac.data"), "[2]")
    }

    /// "Data from a non-parent window is ignored".
    func testADeliveryFromAnotherWindowIsIgnored() throws {
        let shim = try loadShim()
        listen(shim)
        deliver(shim, "'[1]'")
        deliver(shim, "'[2]'", from: "{}")
        deliver(shim, "'[3]'", from: "window")
        XCTAssertEqual(shim.number("heard.length"), 1)
        XCTAssertEqual(json(shim, "window.tarmac.data"), "[1]")
    }

    /// "Bad delivery text is ignored".
    func testATextThatIsNoStringOrNoJSONIsDroppedQuietly() throws {
        let shim = try loadShim()
        listen(shim)
        deliver(shim, "'[1]'")
        for text in ["undefined", "3", "null", "{ a: 1 }", "['[2]']", "''", "'{'", "'[1,]'"] {
            deliver(shim, text)
            XCTAssertEqual(shim.number("heard.length"), 1, text)
            XCTAssertEqual(json(shim, "window.tarmac.data"), "[1]", text)
        }
        shim.run("h.send({ tarmac: 'data' })")
        XCTAssertEqual(shim.number("heard.length"), 1, "no text")
    }

    /// "Bad delivery text is ignored".
    /// A listener that throws is the page's error, not the shim's.
    func testAListenerThatThrowsDoesNotBreakTheNextDelivery() throws {
        let shim = try loadShim()
        shim.run("window.addEventListener('tarmac:data', () => { throw new Error('boom'); })")
        listen(shim)
        deliver(shim, "'[1]'")
        deliver(shim, "'[2]'")
        XCTAssertEqual(json(shim, "window.tarmac.data"), "[2]")
    }

    /// "Page own tarmac object is kept".
    func testAPageThatTookTheGlobalKeepsIt() throws {
        let shim = try loadShim()
        listen(shim)
        shim.run("window.tarmac = { mine: true }")
        deliver(shim, #"'{"n":1}'"#)
        XCTAssertEqual(json(shim, "heard.map((e) => e.detail)"), #"[{"n":1}]"#)
        XCTAssertEqual(json(shim, "window.tarmac"), #"{"mine":true}"#)
    }

    // MARK: - events (2611.0003)

    private func listenForEvents(_ shim: Shim) {
        shim.run("var events = []; window.addEventListener('tarmac:push', (e) => events.push(e));")
    }

    /// `texts` is a JavaScript expression.
    private func sendEvents(_ shim: Shim, _ texts: String, from source: String = "parent") {
        shim.run("h.send({ tarmac: 'events', texts: \(texts) }, \(source))")
    }

    private func consoleEntries(_ shim: Shim) throws -> [NSDictionary] {
        try shim.posted().filter { $0["tarmac"] as? String == "console" }
    }

    /// "Batch fires events in order".
    func testEachTextIsParsedAndDispatchedInOrder() throws {
        let shim = try loadShim()
        listenForEvents(shim)
        sendEvents(shim, #"['{"n":1}', '{"n":2}']"#)
        XCTAssertEqual(json(shim, "events.map((e) => e.type)"), #"["tarmac:push","tarmac:push"]"#)
        XCTAssertEqual(json(shim, "events.map((e) => e.detail)"), #"[{"n":1},{"n":2}]"#)
    }

    /// "Bad JSON text gives one console error".
    /// The line goes through the shim's own relay: a page that took
    /// `console.error` for itself does not keep it from the app (choice 17).
    func testATextThatIsNoJSONIsOneErrorLineAndTheRestAreDispatched() throws {
        let shim = try loadShim()
        listenForEvents(shim)
        shim.run("window.console.error = function () {}")
        sendEvents(shim, #"['{"n":1}', '{bad', '{"n":3}']"#)
        XCTAssertEqual(json(shim, "events.map((e) => e.detail)"), #"[{"n":1},{"n":3}]"#)
        XCTAssertEqual(
            try consoleEntries(shim),
            [["tarmac": "console", "level": "error", "args": ["tarmac:push: not valid JSON"]]]
        )
    }

    /// "Events from another source are ignored".
    func testEventsFromAnotherWindowAreIgnored() throws {
        let shim = try loadShim()
        listenForEvents(shim)
        sendEvents(shim, "['[1]']", from: "{}")
        sendEvents(shim, "['[2]']", from: "window")
        XCTAssertEqual(shim.number("events.length"), 0)
        sendEvents(shim, "['[3]']")
        XCTAssertEqual(json(shim, "events.map((e) => e.detail)"), "[[3]]")
    }

    /// "Events leave window data unchanged".
    func testAnEventLeavesTheDataAsItWas() throws {
        let shim = try loadShim()
        listen(shim)
        listenForEvents(shim)
        deliver(shim, #"'{"n":1}'"#)
        sendEvents(shim, "['[2]']")
        XCTAssertEqual(json(shim, "events.map((e) => e.detail)"), "[[2]]")
        XCTAssertEqual(shim.number("heard.length"), 1, "no tarmac:data")
        XCTAssertEqual(json(shim, "window.tarmac.data"), #"{"n":1}"#)
        XCTAssertEqual(shim.flag("window.tarmac.data === heard[0].detail"), true)

        let none = try loadShim()
        listen(none)
        listenForEvents(none)
        sendEvents(none, "['[2]']")
        XCTAssertEqual(json(none, "events.map((e) => e.detail)"), "[[2]]")
        XCTAssertEqual(none.number("heard.length"), 0)
        XCTAssertEqual(none.flag("window.tarmac.data === undefined"), true)
    }

    /// "Throwing listener does not stop the batch".
    /// The stand-in's `dispatchEvent` lets a listener's error out, as WebKit's
    /// does not: this is the shim's own guard. One listener records and then
    /// throws, so a text after the first is heard only past that guard.
    func testAListenerThatThrowsDoesNotStopTheNextText() throws {
        let shim = try loadShim()
        shim.run(
            "var events = []; window.addEventListener('tarmac:push', (e) => { events.push(e); throw new Error('boom'); });"
        )
        sendEvents(shim, "['[1]', '[2]']")
        XCTAssertEqual(json(shim, "events.map((e) => e.detail)"), "[[1],[2]]")
    }

    /// "Malformed texts give no event and no throw".
    /// `'12'` is a string that would iterate into two texts of JSON; `1` and
    /// `null` are what `JSON.parse` would take after coercing them.
    func testTextsThatAreNoArrayOrEntriesThatAreNoStringGiveNothing() throws {
        let shim = try loadShim()
        listenForEvents(shim)
        for texts in ["'12'", "'[1]'", "undefined", "null", "3", "{ 0: '[1]', length: 1 }"] {
            XCTAssertNil(shim.thrown("h.send({ tarmac: 'events', texts: \(texts) })"), texts)
        }
        shim.run("h.send({ tarmac: 'events' })")
        XCTAssertEqual(shim.number("events.length"), 0)

        sendEvents(shim, #"[1, null, {}, ['[1]'], '{"n":2}', true]"#)
        XCTAssertEqual(json(shim, "events.map((e) => e.detail)"), #"[{"n":2}]"#)
        XCTAssertEqual(try consoleEntries(shim), [])
    }

    // MARK: - list markers (2611.0019)

    /// One plain `li` for the marking pass, and a `getComputedStyle` that
    /// knows one rule of the cascade: a marked item is `none` once a sheet
    /// whose first rule is the marker rule is adopted. Installed after load:
    /// the shim reads none of this until a zoom arrives.
    private func loadShimWithAListItem() throws -> Shim {
        let shim = try loadShim(head: true)
        shim.run(
            """
            (() => {
              const attrs = new Map();
              h.li = {
                nodeType: 1, localName: "li",
                hasAttribute: (n) => attrs.has(n),
                getAttribute: (n) => (attrs.has(n) ? attrs.get(n) : null),
                setAttribute: (n, v) => attrs.set(n, String(v)),
                removeAttribute: (n) => attrs.delete(n),
              };
              const query = document.querySelectorAll;
              document.querySelectorAll = (selector) => (selector === "li" ? [h.li] : query(selector));
              const replace = CSSStyleSheet.prototype.replaceSync;
              CSSStyleSheet.prototype.replaceSync = function (text) {
                if (text.startsWith("li[data-tarmac-marker]")) this.cssRules = [{ selectorText: "li[data-tarmac-marker]" }];
                else replace.call(this, text);
              };
              const sheeted = () => (document.adoptedStyleSheets || [])
                .some((sheet) => sheet.cssRules[0] && sheet.cssRules[0].selectorText === "li[data-tarmac-marker]");
              globalThis.getComputedStyle = (el, pseudo) => pseudo ? { content: pseudo === "::marker" ? "normal" : "none" } : {
                display: "list-item", listStylePosition: "outside", listStyleImage: "none",
                direction: "ltr", writingMode: "horizontal-tb",
                listStyleType: el.hasAttribute("data-tarmac-marker") && sheeted() ? "none" : "disc",
              };
            })()
            """)
        return shim
    }

    /// "Missing native API leaves the page untouched".
    func testAMagnifiedCardMarksAPlainItem() throws {
        let shim = try loadShimWithAListItem()
        shim.run("h.domReady()")
        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(
            shim.run("h.li.getAttribute('data-tarmac-marker')").toString(), "disc",
            "Missing native API leaves the page untouched: the control is marked")
    }

    /// "Missing native API leaves the page untouched".
    func testWithoutANativeTheZoomStillAppliesAndNothingIsMarked() throws {
        let removals = [
            "CSSStyleSheet": "delete globalThis.CSSStyleSheet",
            "adoptedStyleSheets": "delete document.adoptedStyleSheets",
            "MutationObserver": "delete globalThis.MutationObserver",
            "querySelectorAll": "delete document.querySelectorAll",
            "getComputedStyle": "delete globalThis.getComputedStyle",
        ]
        for (native, removal) in removals {
            let shim = try loadShimWithAListItem()
            shim.run(removal)
            shim.run("h.domReady()")
            XCTAssertTrue(
                try shim.hasPosted(Self.ready(meta: "magnify")),
                "Missing native API leaves the page untouched \(native): ready")
            let posts = try shim.posted().count
            let watchers = try shim.count("h.watchers")
            let sheets = try shim.count("h.sheets")

            shim.run("h.send({ tarmac: 'zoom', z: 3 })")

            XCTAssertEqual(
                shim.number("h.style.zoom"), 3, "Missing native API leaves the page untouched \(native): zoom")
            XCTAssertEqual(
                try shim.posted().count, posts, "Missing native API leaves the page untouched \(native): nothing posted"
            )
            XCTAssertEqual(
                shim.flag("h.li.hasAttribute('data-tarmac-marker')"), false,
                "Missing native API leaves the page untouched \(native): no mark")
            XCTAssertEqual(
                try shim.count("h.watchers"), watchers,
                "Missing native API leaves the page untouched \(native): no observer")
            XCTAssertEqual(
                try shim.count("h.sheets"), sheets, "Missing native API leaves the page untouched \(native): no sheet")
        }
    }

    /// "Only a valid zoom makes one observer".
    func testAZoomOf1MakesNoObserverAndNoSheet() throws {
        let shim = try loadShimWithAListItem()
        shim.run("h.domReady()")
        shim.run("h.send({ tarmac: 'zoom', z: 1 })")
        XCTAssertEqual(
            try shim.count("h.watchers"), 1, "Only a valid zoom makes one observer: the colour-scheme observer only")
        XCTAssertEqual(try shim.count("h.sheets"), 1, "Only a valid zoom makes one observer: the media sheet only")
    }

    /// "Only a valid zoom makes one observer".
    func testAMagnifiedCardWatchesTheRootOnceForAddedItems() throws {
        let shim = try loadShimWithAListItem()
        shim.run("h.domReady()")
        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(try shim.count("h.watchers"), 2, "Only a valid zoom makes one observer: one more observer")
        XCTAssertEqual(
            shim.flag(
                "h.watchers[1].observed.length === 1 && h.watchers[1].observed[0].target === document.documentElement"),
            true)
        XCTAssertEqual(
            shim.flag(
                "h.watchers[1].observed[0].options.childList === true && h.watchers[1].observed[0].options.subtree === true"
            ), true)
        XCTAssertEqual(try shim.count("h.sheets"), 2, "Only a valid zoom makes one observer: one marker sheet")

        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(try shim.count("h.watchers"), 2, "Only a valid zoom makes one observer: no second observer")
        XCTAssertEqual(try shim.count("h.sheets"), 2, "Only a valid zoom makes one observer: no second marker sheet")
    }

    /// "Zoom posted before ready marks items after ready".
    func testAZoomHeldUntilReadyStillMarks() throws {
        let shim = try loadShimWithAListItem()
        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(
            shim.flag("h.li.hasAttribute('data-tarmac-marker')"), false,
            "Zoom posted before ready marks items after ready: held, not applied")
        shim.run("h.domReady()")
        XCTAssertEqual(
            shim.number("h.style.zoom"), 3, "Zoom posted before ready marks items after ready: applied at ready")
        XCTAssertEqual(
            shim.run("h.li.getAttribute('data-tarmac-marker')").toString(), "disc",
            "Zoom posted before ready marks items after ready: marked at ready")
    }

    /// "Throwing getComputedStyle breaks nothing in the observer".
    func testAFailureInTheObserverStaysInTheShim() throws {
        let shim = try loadShimWithAListItem()
        shim.run("h.domReady()")
        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        let posts = try shim.posted().count
        shim.run("globalThis.getComputedStyle = () => { throw new Error('style') }")
        shim.run(
            "h.parse('li', { nodeType: 1, isConnected: true, hasAttribute: () => false, querySelectorAll: () => [] })")
        XCTAssertEqual(
            try shim.posted().count, posts, "Throwing getComputedStyle breaks nothing in the observer: nothing posted")
    }

    /// "Only a valid zoom makes one observer".
    func testAZoomThatIsNoMagnificationMakesNoObserver() throws {
        for zoom in ["0", "NaN", "Infinity", "-3"] {
            let shim = try loadShimWithAListItem()
            shim.run("h.domReady()")
            shim.run("h.send({ tarmac: 'zoom', z: \(zoom) })")
            XCTAssertEqual(try shim.count("h.watchers"), 1, "Only a valid zoom makes one observer zoom \(zoom)")
            XCTAssertEqual(
                shim.flag("h.li.hasAttribute('data-tarmac-marker')"), false,
                "Only a valid zoom makes one observer zoom \(zoom)")
        }
    }

    /// "Throwing getComputedStyle breaks nothing on the main pass".
    func testAFailureInThePassStaysInTheShimOnBothPaths() throws {
        for held in [false, true] {
            let shim = try loadShimWithAListItem()
            shim.run("globalThis.getComputedStyle = () => { throw new Error('style') }")
            if !held { shim.run("h.domReady()") }
            shim.run("h.send({ tarmac: 'zoom', z: 3 })")
            if held { shim.run("h.domReady()") }
            XCTAssertEqual(
                shim.number("h.style.zoom"), 3,
                "Throwing getComputedStyle breaks nothing on the main pass held \(held): zoom")
            XCTAssertTrue(
                try shim.hasPosted(Self.ready(meta: "magnify")),
                "Throwing getComputedStyle breaks nothing on the main pass held \(held): ready")
            XCTAssertEqual(
                try shim.posted().count, 2,
                "Throwing getComputedStyle breaks nothing on the main pass held \(held): started and ready, nothing more"
            )
        }
    }

    // MARK: - the media cap (2611.0023)

    /// "Missing or failing sheet APIs break nothing".
    func testWithoutTheMediaSheetTheRestOfTheShimStillRuns() throws {
        let cases: [(String, Shim)] = [
            ("no CSSStyleSheet", try loadShim(omitting: "CSSStyleSheet")),
            ("no adoptedStyleSheets", try loadShim(before: "delete document.adoptedStyleSheets")),
            (
                "the media rule throws",
                try loadShim(fonts: Self.fonts, before: "h.refuse = (text) => text.includes('object-fit')")
            ),
        ]
        for (name, shim) in cases {
            shim.run("h.domReady()")
            XCTAssertEqual(
                try shim.posted().map { $0["tarmac"] as? String }, ["started", "ready"],
                "Missing or failing sheet APIs break nothing \(name): posted")
            shim.run("h.send({ tarmac: 'zoom', z: 3 })")
            XCTAssertEqual(shim.number("h.style.zoom"), 3, "Missing or failing sheet APIs break nothing \(name): zoom")
            XCTAssertEqual(
                try shim.posted().count, 2, "Missing or failing sheet APIs break nothing \(name): nothing more posted")
        }
        let refused = cases[2].1
        XCTAssertEqual(try refused.count("h.refused"), 1, "Missing or failing sheet APIs break nothing: one throw")
        XCTAssertEqual(
            try declared(refused), try vars(Self.fonts), "Missing or failing sheet APIs break nothing: the font sheet")
    }

    /// "Boot sheet holds exactly the two cap rules".
    func testARawShimAdoptsTheMediaSheetAtBoot() throws {
        let shim = try loadShim()
        XCTAssertEqual(
            try shim.count("document.adoptedStyleSheets"), 1, "Boot sheet holds exactly the two cap rules: one sheet")
        let rules = """
            :where(svg[viewBox], img, video, canvas) { max-width: min(100%, 1080px); object-fit: contain; }
            :where(img[width], svg[viewBox][width], video[width]) { height: auto; }
            """
        XCTAssertEqual(
            shim.run("document.adoptedStyleSheets[0].text.replace(/\\s/g, '')").toString(),
            rules.filter { !$0.isWhitespace }
        )
    }

    func test2611_0023D5TheMediaSheetIsAdoptedAfterTheStartedPostAndBeforeTheFirstListener() throws {
        let shim = try loadShim(head: true)
        XCTAssertEqual(
            shim.run("JSON.stringify(h.sheets[0].atConstruction.posted)").toString(),
            #"[{"tarmac":"started","source":"tarmac-card://doc/card.html?v=1"}]"#,
            "D5: after started"
        )
        XCTAssertEqual(try shim.strings("h.sheets[0].atConstruction.listeners"), [], "D5: before the first listener")
    }
}
