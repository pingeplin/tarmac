import JavaScriptCore
import XCTest

/// The HTML card shim as it ships (`TarmacApp/Resources/Web/card_shim.js`),
/// run in a stand-in window with stand-in schedulers: the scheduler gate of
/// spec 2609.0002 (S5–S28, S40–S42) and the zoom handshake of spec 2609.0003
/// (S8–S10). Scenario ids are per spec and collide — both specs have an S8,
/// an S9 and an S10 — so a 2609.0003 test names its spec.
///
/// Two rules of the stand-in window make the assertions mean anything:
///
/// - All six scheduler natives are on the window before the shim runs. The
///   shim captures them at load, so a late install would hand it other
///   functions than the ones these tests observe.
/// - Native ids come from one range per family, far above the shim's own
///   counter, which starts at 1. Without that, "the native was called with
///   the native id" cannot be told from a wrapper passing its own id through,
///   and S7 and S40 pass whatever the shim does.
///
/// "The card calls X" is always spelled `window.X(...)`: the wrappers are
/// installed on `window`, and going through it is what lets S6 say which
/// reference a resume uses.
final class CardShimTests: XCTestCase {
    private static let rafIdBase = 1000
    private static let timeoutIdBase = 2000
    private static let intervalIdBase = 3000

    /// The stand-in window, taking the document's `tarmac-zoom` meta and the
    /// one native to leave out. The window is the global object, as it is in
    /// a page; `h` is what a test drives it with and reads back from.
    private static let page = """
    (function (meta, omitNative) {
      const listeners = new Map();
      const docListeners = new Map();
      const posted = [];
      const style = {};

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
        parent,
        addEventListener: (type, fn) => add(listeners, type, fn),
        removeEventListener() {},
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

        document: {
          documentElement: { style },
          addEventListener: (type, fn) => add(docListeners, type, fn),
          querySelector(sel) {
            if (sel === 'meta[name="tarmac-zoom"]' && meta !== null) return { content: meta };
            return null;
          },
        },
      });
      if (omitNative) delete globalThis[omitNative];

      globalThis.h = {
        posted,
        style,
        calls,
        send: (data, source = parent) => emit(listeners, "message", { source, data }),
        fire: (type, event) => emit(listeners, type, event),
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

    private func source() throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: app.appendingPathComponent("Sources/TarmacApp/Resources/Web/card_shim.js"), encoding: .utf8
        )
    }

    private func window(meta: String?, omitting native: String? = nil) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("the script threw: \(String(describing: error))") }
        context.evaluateScript(Self.page).call(withArguments: [meta as Any? ?? NSNull(), native as Any? ?? NSNull()])
        return context
    }

    private func loadShim(meta: String? = "magnify") throws -> Shim {
        let context = try window(meta: meta)
        context.evaluateScript(try source())
        return Shim(context: context)
    }

    // MARK: - the shipped shim loads and still handshakes (S5)

    func testS5PostsReadyWithTheDocumentsOwnMetaAndAppliesAHostZoom() throws {
        let shim = try loadShim(meta: "magnify")

        shim.run("h.domReady()")
        XCTAssertTrue(try shim.hasPosted(["tarmac": "ready", "meta": "magnify"]), "S5: ready")

        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "S5: zoom")
    }

    func testS5ReportsANullMetaForADocumentWithNoTarmacZoomTag() throws {
        let shim = try loadShim(meta: nil)
        shim.run("h.domReady()")
        XCTAssertTrue(try shim.hasPosted(["tarmac": "ready", "meta": NSNull()]), "S5")
    }

    /// What matters is that the natives exist before the shim runs, so it
    /// captures the functions these tests observe; a `typeof` after load would
    /// only re-check the shim's own wrappers. A shim that could load with one
    /// missing would have captured nothing, and every other scenario would
    /// pass whatever it did.
    func testS5FailsLoudlyIfASchedulerNativeIsMissingWhenTheShimCaptures() throws {
        for native in ["requestAnimationFrame", "cancelAnimationFrame", "setTimeout", "clearTimeout", "setInterval"] {
            let context = try window(meta: "magnify", omitting: native)
            var thrown: JSValue?
            context.exceptionHandler = { _, error in thrown = error }
            context.evaluateScript(try source())
            XCTAssertNotNil(thrown, "S5: the shim loaded without \(native)")
        }
    }

    // MARK: - the gate uses the natives captured at load, not the current globals (S6)

    /// The callbacks are issued before the globals are replaced: once they
    /// are, card code can no longer reach the wrappers at all.
    func testS6CancelsAndResumesThroughCapturedReferencesAfterACardReplacesThem() throws {
        let shim = try loadShim()
        shim.run("""
        var ran = [];
        window.requestAnimationFrame(() => ran.push("frame"));
        var timeoutId = window.setTimeout(() => ran.push("timeout"), 5);
        """)
        let nativeFrameId = try shim.id("h.calls.requestAnimationFrame[0]")

        shim.run("""
        var boom = () => { throw new Error("card replaced a scheduler global"); };
        window.requestAnimationFrame = boom;
        window.setTimeout = boom;
        window.cancelAnimationFrame = boom;
        """)

        shim.pause()
        XCTAssertTrue(try shim.ids("h.calls.cancelAnimationFrame").contains(nativeFrameId), "S6: cancel")

        shim.run("h.fireTimeout(timeoutId)")
        XCTAssertEqual(try shim.strings("ran"), [], "S6: ran while paused")

        shim.resumeAndDrain()
        XCTAssertEqual(try shim.strings("ran").sorted(), ["frame", "timeout"], "S6: resume")
    }

    // MARK: - requestAnimationFrame gate (S7–S11)

    func testS7PauseCallsTheNativeCancelAnimationFrameWithTheOutstandingNativeId() throws {
        let shim = try loadShim()
        shim.run("var ran = false; window.requestAnimationFrame(() => { ran = true; });")
        let nativeId = try shim.id("h.calls.requestAnimationFrame[0]")
        XCTAssertGreaterThanOrEqual(nativeId, Self.rafIdBase, "S7: a native id")

        shim.pause()

        XCTAssertEqual(try shim.ids("h.calls.cancelAnimationFrame"), [nativeId], "S7: cancelled")
        XCTAssertEqual(try shim.ids("h.pendingFrameIds()"), [], "S7: pending")
        XCTAssertEqual(shim.flag("ran"), false, "S7: ran")
    }

    func testS8APausedRAFCallReachesNoNativeAndStillReturnsAUsableId() throws {
        let shim = try loadShim()
        shim.pause()
        let before = try shim.count("h.calls.requestAnimationFrame")

        shim.run("var a = window.requestAnimationFrame(() => {}); var b = window.requestAnimationFrame(() => {});")

        XCTAssertEqual(try shim.count("h.calls.requestAnimationFrame"), before, "S8: reached the native")
        XCTAssertFalse(shim.run("a").isUndefined, "S8: first id")
        XCTAssertFalse(shim.run("b").isUndefined, "S8: second id")
        XCTAssertEqual(shim.flag("Object.is(a, b)"), false, "S8: the ids are one")
    }

    func testS9ResumeIssuesExactlyOneNativeFrameAndDeliversAllHeldCallbacksOnceInOrder() throws {
        let shim = try loadShim()
        shim.run("var ran = []; window.requestAnimationFrame(() => ran.push('pre'));")
        shim.pause()
        shim.run("""
        window.requestAnimationFrame(() => ran.push("mid"));
        window.requestAnimationFrame(() => ran.push("post"));
        """)

        let nativeCallsBefore = try shim.count("h.calls.requestAnimationFrame")
        shim.resume()
        XCTAssertEqual(try shim.count("h.calls.requestAnimationFrame"), nativeCallsBefore + 1, "S9: one native frame")

        shim.run("h.driveFrame(1)")
        XCTAssertEqual(try shim.strings("ran"), ["pre", "mid", "post"], "S9: delivered")
    }

    func testS10CancelAnimationFrameOnAHeldIdDropsOnlyThatCallback() throws {
        let shim = try loadShim()
        shim.pause()
        shim.run("""
        var ran = [];
        var doomed = window.requestAnimationFrame(() => ran.push("doomed"));
        window.requestAnimationFrame(() => ran.push("kept"));
        window.cancelAnimationFrame(doomed);
        """)
        shim.resumeAndDrain()

        XCTAssertEqual(try shim.strings("ran"), ["kept"], "S10")
    }

    func testS11AReIssuedCallbackReceivesTheFreshCatchUpTimestamp() throws {
        let shim = try loadShim()
        shim.run("var seen = []; window.requestAnimationFrame((ts) => seen.push(ts));")
        shim.pause()
        shim.resume()
        shim.run("h.driveFrame(987)")

        XCTAssertEqual(try shim.ids("seen"), [987], "S11")
    }

    // MARK: - setInterval gate (S12–S14)

    func testS12APausedIntervalDeliversNothingWhileTheNativeKeepsTicking() throws {
        let shim = try loadShim()
        shim.run("var ticks = 0; window.setInterval(() => { ticks++; }, 16);")
        let nativeId = try shim.id("h.calls.setInterval[0].id")
        XCTAssertGreaterThanOrEqual(nativeId, Self.intervalIdBase, "S12: a native id")

        shim.pause()
        shim.run("h.tickInterval(\(nativeId)); h.tickInterval(\(nativeId)); h.tickInterval(\(nativeId));")

        XCTAssertEqual(shim.number("ticks"), 0, "S12: delivered")
        XCTAssertFalse(try shim.ids("h.calls.clearInterval").contains(nativeId), "S12: the native was cleared")
    }

    func testS13MissedTicksAreDroppedNotFlushedOnResume() throws {
        let shim = try loadShim()
        shim.run("var ticks = 0; window.setInterval(() => { ticks++; }, 16);")
        let nativeId = try shim.id("h.calls.setInterval[0].id")

        shim.pause()
        shim.run("h.tickInterval(\(nativeId)); h.tickInterval(\(nativeId)); h.tickInterval(\(nativeId));")

        shim.resumeAndDrain()
        XCTAssertEqual(shim.number("ticks"), 0, "S13: the resume itself delivered")

        shim.run("h.tickInterval(\(nativeId))")
        XCTAssertEqual(shim.number("ticks"), 1, "S13: one tick, not the three missed")
    }

    func testS14ClearIntervalWhilePausedReachesTheNativeAndEndsTheInterval() throws {
        let shim = try loadShim()
        shim.run("var ticks = 0; var id = window.setInterval(() => { ticks++; }, 16);")
        let nativeId = try shim.id("h.calls.setInterval[0].id")

        shim.pause()
        shim.run("window.clearInterval(id)")
        XCTAssertTrue(try shim.ids("h.calls.clearInterval").contains(nativeId), "S14: cleared natively")

        shim.resumeAndDrain()
        XCTAssertEqual(shim.number("ticks"), 0, "S14: delivered")
        XCTAssertEqual(
            shim.thrown("h.tickInterval(\(nativeId))"), "no armed native interval \(nativeId)", "S14: still armed"
        )
    }

    // MARK: - setTimeout gate (S15–S21)

    /// Issued while running: a gate at call time would let this one through.
    func testS15ATimeoutWhoseNativeTimerFiresDuringThePauseIsDivertedNotRun() throws {
        let shim = try loadShim()
        shim.run("var ran = false; var id = window.setTimeout(() => { ran = true; }, 16);")

        shim.pause()
        shim.run("h.fireTimeout(id)")

        XCTAssertEqual(shim.flag("ran"), false, "S15")
    }

    func testS16ResumeFlushesItExactlyOnceThroughANativeSetTimeoutZeroHop() throws {
        let shim = try loadShim()
        shim.run("var runs = 0; var id = window.setTimeout(() => { runs++; }, 16);")
        shim.pause()
        shim.run("h.fireTimeout(id)")

        let before = try shim.count("h.calls.setTimeout")
        shim.resume()

        XCTAssertEqual(shim.number("runs"), 0, "S16: ran inside the message listener")
        XCTAssertFalse(shim.run("h.calls.setTimeout[\(before)]").isUndefined, "S16: the hop")
        XCTAssertEqual(shim.number("h.calls.setTimeout[\(before)].delay"), 0, "S16: the hop's delay")

        shim.run("h.drainTimeouts()")
        XCTAssertEqual(shim.number("runs"), 1, "S16: flushed")

        shim.run("h.drainTimeouts()")
        XCTAssertEqual(shim.number("runs"), 1, "S16: flushed twice")
    }

    func testS17ExtraArgumentsSurviveTheDivertAndTheFlush() throws {
        let shim = try loadShim()
        shim.run("var seen = []; var id = window.setTimeout((...args) => seen.push(args), 16, 'a', 7);")
        shim.pause()
        shim.run("h.fireTimeout(id)")
        shim.resumeAndDrain()

        XCTAssertEqual(shim.run("seen").toArray() as NSArray?, [["a", 7]], "S17")
    }

    func testS18ClearTimeoutOnADivertedCallbackStopsItRunningAtAnyPoint() throws {
        let shim = try loadShim()
        shim.run("var ran = false; var id = window.setTimeout(() => { ran = true; }, 16);")
        shim.pause()
        shim.run("h.fireTimeout(id)")
        XCTAssertEqual(shim.flag("ran"), false, "S18: ran during the pause")

        shim.run("window.clearTimeout(id)")
        shim.resumeAndDrain()

        XCTAssertEqual(shim.flag("ran"), false, "S18: ran on resume")
    }

    func testS19ATimeoutIssuedWhilePausedArmsTheNativeImmediatelyWithItsOwnDelay() throws {
        let shim = try loadShim()
        shim.pause()
        let before = try shim.count("h.calls.setTimeout")

        shim.run("window.setTimeout(() => {}, 5000)")

        XCTAssertFalse(shim.run("h.calls.setTimeout[\(before)]").isUndefined, "S19: armed")
        XCTAssertEqual(shim.number("h.calls.setTimeout[\(before)].delay"), 5000, "S19: delay")
    }

    func testS20BothFamiliesFlushInIssueOrderWithinEachFamily() throws {
        let shim = try loadShim()
        shim.run("""
        var ran = [];
        var a = window.setTimeout(() => ran.push("tA"), 16);
        var b = window.setTimeout(() => ran.push("tB"), 16);
        window.requestAnimationFrame(() => ran.push("fX"));
        """)

        shim.pause()
        shim.run("""
        h.fireTimeout(a);
        h.fireTimeout(b);
        window.requestAnimationFrame(() => ran.push("fY"));
        window.requestAnimationFrame(() => ran.push("fZ"));
        """)

        shim.resumeAndDrain()

        let ran = try shim.strings("ran")
        XCTAssertEqual(ran.filter { $0.hasPrefix("t") }, ["tA", "tB"], "S20: timeouts")
        XCTAssertEqual(ran.filter { $0.hasPrefix("f") }, ["fX", "fY", "fZ"], "S20: frames")
        // No interleaving under this drain order, which is what a single
        // shared queue would produce. The order across families is the
        // engine's (S38, QA), not a promise of the shim.
        XCTAssertEqual(ran, ["tA", "tB", "fX", "fY", "fZ"], "S20: interleaved")
    }

    func testS21EachFamilyIsCarriedByItsOwnCapturedNativePrimitive() throws {
        let shim = try loadShim()
        shim.run("var t = window.setTimeout(() => {}, 16); window.requestAnimationFrame(() => {});")
        shim.pause()
        shim.run("h.fireTimeout(t)")

        let timeoutsBefore = try shim.count("h.calls.setTimeout")
        let framesBefore = try shim.count("h.calls.requestAnimationFrame")
        shim.resume()

        XCTAssertEqual(try shim.count("h.calls.setTimeout"), timeoutsBefore + 1, "S21: one hop")
        XCTAssertEqual(shim.number("h.calls.setTimeout[\(timeoutsBefore)].delay"), 0, "S21: the hop's delay")
        XCTAssertEqual(try shim.count("h.calls.requestAnimationFrame"), framesBefore + 1, "S21: one frame")
    }

    // MARK: - idempotence and re-pause (S22–S25)

    func testS22ARepeatPauseReCancelsNothingAndDoesNotDuplicateDeliveries() throws {
        let shim = try loadShim()
        shim.run("""
        var ran = [];
        window.requestAnimationFrame(() => ran.push("frame"));
        var t = window.setTimeout(() => ran.push("timeout"), 16);
        """)

        shim.pause()
        shim.run("h.fireTimeout(t)")
        let cancelsAfterFirstPause = try shim.ids("h.calls.cancelAnimationFrame")

        shim.pause()
        shim.pause()
        XCTAssertEqual(try shim.ids("h.calls.cancelAnimationFrame"), cancelsAfterFirstPause, "S22: re-cancelled")

        shim.resumeAndDrain()
        XCTAssertEqual(try shim.strings("ran"), ["timeout", "frame"], "S22: delivered")
    }

    /// The fixture that matters is live, outstanding work when the redundant
    /// resume arrives: a resume that skips its own early-out would sweep it
    /// into a catch-up flush, delivering it early here and again when its real
    /// native timers fire.
    func testS23AResumeWhileRunningTouchesNothingTheCardAlreadyHasInFlight() throws {
        let shim = try loadShim()
        shim.run("""
        var ran = [];
        window.requestAnimationFrame(() => ran.push("frame"));
        var t = window.setTimeout(() => ran.push("timeout"), 16);
        """)

        let framesBefore = try shim.count("h.calls.requestAnimationFrame")
        let timeoutsBefore = try shim.count("h.calls.setTimeout")
        shim.resume()

        XCTAssertEqual(try shim.count("h.calls.requestAnimationFrame"), framesBefore, "S23: a catch-up frame")
        XCTAssertEqual(try shim.count("h.calls.setTimeout"), timeoutsBefore, "S23: a hop")
        XCTAssertEqual(try shim.strings("ran"), [], "S23: delivered early")

        shim.run("h.driveFrame(1); h.fireTimeout(t);")
        XCTAssertEqual(try shim.strings("ran"), ["frame", "timeout"], "S23: on their own native fires")

        shim.run("h.driveFrame(2); h.drainTimeouts();")
        XCTAssertEqual(try shim.strings("ran"), ["frame", "timeout"], "S23: delivered again")
    }

    func testS24ARePauseDuringTheFlushReHoldsBothFamiliesAndLosesNeither() throws {
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
        XCTAssertEqual(try shim.ids("h.calls.cancelAnimationFrame"), [nativeFrameId, catchUpId], "S24: cancelled")

        shim.run("h.drainTimeouts(); h.driveFrame(1);")
        XCTAssertEqual(try shim.strings("ran"), [], "S24: ran while paused")

        shim.resumeAndDrain(2)
        XCTAssertEqual(try shim.strings("ran"), ["timeout", "frame"], "S24: each exactly once")
    }

    func testS25ACullArrivingBeforeDOMContentLoadedStillPauses() throws {
        let shim = try loadShim()

        shim.pause()
        XCTAssertFalse(try shim.posted().contains { $0["tarmac"] as? String == "ready" }, "S25: ready was posted")

        let before = try shim.count("h.calls.requestAnimationFrame")
        shim.run("window.requestAnimationFrame(() => {})")

        XCTAssertEqual(try shim.count("h.calls.requestAnimationFrame"), before, "S25: reached the native")
    }

    // MARK: - a delivered callback is never delivered again (S41)

    // Every other exactly-once assertion stops after one pause → resume round
    // trip. A board culls and un-culls a card constantly as the user pans, and
    // failing to drop an entry after a natural frame, after a catch-up flush or
    // after a timeout flush leaves spent callbacks in the held queues, where
    // each later un-cull delivers them again — invisible inside one trip.

    func testS41AFrameDeliveredNaturallyIsNotReDeliveredByALaterRoundTrip() throws {
        let shim = try loadShim()
        shim.run("var ran = []; window.requestAnimationFrame(() => ran.push('frame')); h.driveFrame(1);")
        XCTAssertEqual(try shim.strings("ran"), ["frame"], "S41: delivered while running")

        shim.pause()
        shim.resumeAndDrain(2)
        XCTAssertEqual(try shim.strings("ran"), ["frame"], "S41: delivered again")
    }

    func testS41AFrameDeliveredByACatchUpFlushIsNotReDeliveredByTheNextOne() throws {
        let shim = try loadShim()
        shim.pause()
        shim.run("var ran = []; window.requestAnimationFrame(() => ran.push('frame'));")
        shim.resumeAndDrain(1)
        XCTAssertEqual(try shim.strings("ran"), ["frame"], "S41: flushed")

        shim.pause()
        shim.resumeAndDrain(2)
        XCTAssertEqual(try shim.strings("ran"), ["frame"], "S41: flushed again")
    }

    func testS41ATimeoutDeliveredByAFlushIsNotReDeliveredByTheNextOne() throws {
        let shim = try loadShim()
        shim.run("var ran = []; var t = window.setTimeout(() => ran.push('timeout'), 16);")
        shim.pause()
        shim.run("h.fireTimeout(t)")
        shim.resumeAndDrain(1)
        XCTAssertEqual(try shim.strings("ran"), ["timeout"], "S41: flushed")

        shim.pause()
        shim.resumeAndDrain(2)
        XCTAssertEqual(try shim.strings("ran"), ["timeout"], "S41: flushed again")
    }

    func testS41SurvivesSeveralRoundTripsOverBothFamiliesAtOnce() throws {
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

        XCTAssertEqual(try shim.strings("ran"), ["timeout", "frame"], "S41: delivered")

        // Once the queues have drained, later round trips must be free: only
        // the first resume needed a catch-up frame and a hop. A resume that
        // schedules either with nothing to flush leaves a pending native
        // request behind on every un-cull — the standing charge the gate
        // exists to remove.
        XCTAssertEqual(try shim.count("h.calls.requestAnimationFrame"), 2, "S41: the card's frame and one catch-up")
        XCTAssertEqual(try shim.count("h.calls.setTimeout"), timeoutsBefore + 2, "S41: the card's timeout and one hop")

        // A spent catch-up id must not be kept and cancelled by the next pause.
        XCTAssertEqual(try shim.ids("h.calls.cancelAnimationFrame"), [nativeFrameId], "S41: cancelled")
    }

    // MARK: - a throwing flushed callback is isolated and reported (S42)

    /// A throwing callback in the middle of each queue: the ones issued after
    /// it must still be delivered. The native schedulers give each callback
    /// its own task; the flush runs them in one loop, so it has to isolate
    /// them itself.
    func testS42DoesNotStrandTheRestOfTheQueueInEitherFamily() throws {
        let shim = try loadShim()
        shim.run("""
        var ran = [];
        var t1 = window.setTimeout(() => ran.push("t1"), 16);
        var t2 = window.setTimeout(() => { throw new Error("boom-timeout"); }, 16);
        var t3 = window.setTimeout(() => ran.push("t3"), 16);
        """)
        shim.pause()
        shim.run("""
        h.fireTimeout(t1);
        h.fireTimeout(t2);
        h.fireTimeout(t3);

        window.requestAnimationFrame(() => ran.push("f1"));
        window.requestAnimationFrame(() => { throw new Error("boom-frame"); });
        window.requestAnimationFrame(() => ran.push("f3"));
        """)

        shim.resumeAndDrain()

        XCTAssertEqual(try shim.strings("ran"), ["t1", "t3", "f1", "f3"], "S42")
    }

    /// The live path lets a throw reach `window.onerror` and the error relay;
    /// swallowing it here would make a card's exception vanish exactly when
    /// its callback happened to be flushed after a cull.
    func testS42RelaysTheExceptionRatherThanSwallowingIt() throws {
        let shim = try loadShim()
        shim.run("var t = window.setTimeout(() => { throw new Error('boom-timeout'); }, 16);")
        shim.pause()
        shim.run("h.fireTimeout(t)")
        shim.resumeAndDrain()

        XCTAssertTrue(try shim.hasPosted(["tarmac": "console", "level": "error", "args": ["boom-timeout"]]), "S42")
    }

    // MARK: - the never-paused path stays transparent (S40)

    func testS40ForwardsEveryCancelToItsCapturedNativeAndRunsNothing() throws {
        let shim = try loadShim()
        shim.run("""
        var ran = [];
        var frame = window.requestAnimationFrame(() => ran.push("frame"));
        var timeout = window.setTimeout(() => ran.push("timeout"), 16);
        var interval = window.setInterval(() => ran.push("interval"), 16);
        """)

        let nativeFrame = try shim.id("h.calls.requestAnimationFrame[0]")
        let nativeTimeout = try shim.id("h.calls.setTimeout[0].id")
        let nativeInterval = try shim.id("h.calls.setInterval[0].id")

        shim.run("window.cancelAnimationFrame(frame); window.clearTimeout(timeout); window.clearInterval(interval);")

        XCTAssertEqual(try shim.ids("h.calls.cancelAnimationFrame"), [nativeFrame], "S40: frame")
        XCTAssertEqual(try shim.ids("h.calls.clearTimeout"), [nativeTimeout], "S40: timeout")
        XCTAssertEqual(try shim.ids("h.calls.clearInterval"), [nativeInterval], "S40: interval")

        shim.run("h.driveFrame(1); h.drainTimeouts();")
        XCTAssertEqual(try shim.strings("ran"), [], "S40: ran")
    }

    // MARK: - relays are never gated (S26)

    func testS26APausedCardCanStillReportConsoleErrorsRejectionsAndEscape() throws {
        let shim = try loadShim()
        shim.pause()

        shim.run("""
        window.console.log("x");
        h.fire("error", { message: "boom" });
        h.fire("unhandledrejection", { reason: "nope" });
        h.fire("keydown", { key: "Escape" });
        """)

        XCTAssertTrue(try shim.hasPosted(["tarmac": "console", "level": "log", "args": ["x"]]), "S26: console")
        XCTAssertTrue(try shim.hasPosted(["tarmac": "console", "level": "error", "args": ["boom"]]), "S26: error")
        XCTAssertTrue(try shim.hasPosted(["tarmac": "console", "level": "error", "args": ["nope"]]), "S26: rejection")
        XCTAssertTrue(try shim.hasPosted(["tarmac": "escape"]), "S26: escape")
    }

    /// Ready is what carries the born-culled state.
    func testS26ReadyStillPostsWhilePaused() throws {
        let shim = try loadShim()
        shim.pause()
        shim.run("h.domReady()")
        XCTAssertTrue(try shim.hasPosted(["tarmac": "ready", "meta": "magnify"]), "S26")
    }

    // MARK: - hostile and malformed cull messages (S27, S28)

    func testS27ACullFromAnySourceOtherThanWindowParentIsIgnored() throws {
        let shim = try loadShim()
        shim.run("h.send({ tarmac: 'cull', culled: true }, { not: 'parent' })")
        XCTAssertTrue(try shim.stillRunning(), "S27")
    }

    func testS28AMalformedCullLeavesTheGateStateUnchangedFromEitherState() throws {
        let running = try loadShim()
        running.run("h.send({ tarmac: 'cull' })")
        XCTAssertTrue(try running.stillRunning(), "S28: running, no culled key")
        running.run("h.send({ tarmac: 'cull', culled: 'true' })")
        XCTAssertTrue(try running.stillRunning(), "S28: running, culled a string")

        // The half that carries the weight: from paused, a naive
        // `paused = !!d.culled` would un-pause on the message with no key.
        let paused = try loadShim()
        paused.pause()
        paused.run("h.send({ tarmac: 'cull' })")
        XCTAssertFalse(try paused.stillRunning(), "S28: paused, no culled key")
        paused.run("h.send({ tarmac: 'cull', culled: 'true' })")
        XCTAssertFalse(try paused.stillRunning(), "S28: paused, culled a string")
    }

    func testS28TheRelaysStillWorkAfterAMalformedCull() throws {
        let shim = try loadShim()
        shim.run("h.send({ tarmac: 'cull', culled: {} }); window.console.log('alive');")
        XCTAssertTrue(try shim.hasPosted(["tarmac": "console", "level": "log", "args": ["alive"]]), "S28")
    }

    // MARK: - 2609.0003 (#99): the host may post zoom more than once per document

    func test2609_0003S8AZoomArrivingBeforeDOMContentLoadedIsRetainedNotDropped() throws {
        let shim = try loadShim(meta: "magnify")

        // The negative control: without it "the zoom landed" cannot be told
        // from "the shim applies whatever arrives, whenever".
        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertTrue(shim.run("h.style.zoom").isUndefined, "2609.0003 S8: applied on arrival")

        shim.run("h.domReady()")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "2609.0003 S8: retained")
        XCTAssertTrue(try shim.hasPosted(["tarmac": "ready", "meta": "magnify"]), "2609.0003 S8: ready")
    }

    /// The premise of the #99 fix: the host re-posts the same constant on a
    /// self-reload, so a shim that ignored everything after the first zoom
    /// would leave the reloaded document unzoomed. The values are distinct
    /// because re-sending 3 and reading 3 cannot tell "applied again" from
    /// "ignored". That a repeat causes no relayout is not shown here — the
    /// stand-in `style` has no layout behind it (2609.0003 S14, QA).
    func test2609_0003S9EveryPostReadyZoomIsAppliedNotJustTheFirst() throws {
        let shim = try loadShim(meta: "magnify")
        shim.run("h.domReady()")
        let postedAfterReady = try shim.posted().count

        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "2609.0003 S9: first")
        shim.run("h.send({ tarmac: 'zoom', z: 4 })")
        XCTAssertEqual(shim.number("h.style.zoom"), 4, "2609.0003 S9: second")
        shim.run("h.send({ tarmac: 'zoom', z: 3 })")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "2609.0003 S9: third")

        XCTAssertEqual(try shim.posted().count, postedAfterReady, "2609.0003 S9: a zoom was answered")
    }

    func test2609_0003S10ARepeatZoomFromAnySourceButWindowParentIsIgnored() throws {
        let shim = try loadShim(meta: "magnify")
        shim.run("h.domReady(); h.send({ tarmac: 'zoom', z: 3 });")

        shim.run("h.send({ tarmac: 'zoom', z: 40 }, { nested: 'iframe' })")
        XCTAssertEqual(shim.number("h.style.zoom"), 3, "2609.0003 S10")
    }

    // MARK: - the wheel is not a message (2610.0002 S23)

    /// The web view takes the wheel itself, so a `scroll` from the host is one
    /// more message the shim does not know: it scrolls nothing, and the
    /// listener is still there for the next one.
    func test2610S23AScrollFromTheHostScrollsNothing() throws {
        let shim = try loadShim()
        shim.run("var scrolled = []; window.scrollBy = (dx, dy) => scrolled.push([dx, dy]);")

        shim.run("h.send({ tarmac: 'scroll', dx: 4, dy: -9 })")
        XCTAssertEqual(try shim.count("scrolled"), 0, "2610.0002 S23: scrollBy")

        shim.pause()
        shim.run("window.requestAnimationFrame(() => {});")
        XCTAssertEqual(try shim.ids("h.pendingFrameIds()"), [], "2610.0002 S23: a cull after it still pauses")
    }

    // MARK: - the never-paused path, beyond the cancels

    func testALiveFrameCallbackReceivesTheNativeTimestamp() throws {
        let shim = try loadShim()
        shim.run("var seen = []; window.requestAnimationFrame((ts) => seen.push(ts)); h.driveFrame(321);")
        XCTAssertEqual(shim.number("seen[0]"), 321)
    }

    func testALiveTimeoutKeepsItsExtraArguments() throws {
        let shim = try loadShim()
        shim.run("var seen = []; var id = window.setTimeout((...args) => seen.push(args), 16, 'a', 7); h.fireTimeout(id);")
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
        shim.run("var spent = window.requestAnimationFrame(() => {}); h.driveFrame(1); window.cancelAnimationFrame(spent);")
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

    /// The host pins a real boolean (`CardHostMessageTests`); this is the shim's half.
    func testS28ANumberIsNoBooleanToTheGateFromEitherState() throws {
        let running = try loadShim()
        running.run("h.send({ tarmac: 'cull', culled: 1 })")
        XCTAssertTrue(try running.stillRunning(), "S28: running, culled 1")

        let paused = try loadShim()
        paused.pause()
        paused.run("h.send({ tarmac: 'cull', culled: 0 })")
        XCTAssertFalse(try paused.stillRunning(), "S28: paused, culled 0")
    }
}
