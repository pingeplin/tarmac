#if DEBUG
import AppKit
import TarmacKit
import TarmacTerm

/// Answers one QA-driver request (parity rows Q8–Q21). Which verb acts on what,
/// and every refusal, is `DevRouting`'s; each verb here only carries out its
/// route and reads back what it observed.
///
/// Verbs inject real input rather than calling the controller, so a scenario
/// exercises the paths a user does. `zoom` is the one exception: it goes
/// through the board's own viewport commit.
@MainActor
final class DevVerbs {
    let controller: AppController
    let quitGuard: QuitGuardController
    let window: NSWindow
    /// Where the last `focus` pressed each terminal, in that terminal's own
    /// coordinates: the next press keeps clear of it (`DevPointer.press`).
    private var lastPress: [String: CGPoint] = [:]

    init(controller: AppController, quitGuard: QuitGuardController, window: NSWindow) {
        self.controller = controller
        self.quitGuard = quitGuard
        self.window = window
    }

    var input: DevInput {
        DevInput(window: window) { [controller] target in controller.handlePress(on: target) }
    }

    private var reader: DevSnapshotReader { DevSnapshotReader(controller: controller, quitGuard: quitGuard) }
    private var board: BoardView { controller.activeBoard.view }

    func answer(_ request: DevRequest) async -> DevReply {
        // A board that is being switched away from is out of the window for a moment.
        guard board.window === window else {
            return DevError(.appNotReady, "no board is on screen yet").reply
        }
        let reply: DevReply
        do {
            reply = try await run(DevRouting.route(request, in: reader.routingContext))
        } catch let error as DevError {
            reply = error.reply
        } catch {
            reply = DevError(.driverThrew, "\(error)").reply
        }
        log(request, reply)
        return reply
    }

    /// The scenario suite reads a few fields off a reply and drops the rest,
    /// so what each verb did — which way a press was delivered, whether the
    /// app was activated — is also left in the app's own output. A snapshot is
    /// a read, and large.
    private func log(_ request: DevRequest, _ reply: DevReply) {
        if case .snapshot = request { return }
        FileHandle.standardError.write(Data("tarmac: dev \(request) -> \(reply.body)\n".utf8))
    }

    private func run(_ route: DevRouting.Route) async throws -> DevReply {
        switch route {
        case .refused(let error):
            throw error
        case .snapshot(let until, let timeoutMs):
            return try await snapshot(until: until, timeoutMs: timeoutMs)
        case .press(let combo, let holdMs, let ageMs, let busyMs):
            return ok(try await press(combo: combo, holdMs: holdMs, ageMs: ageMs, busyMs: busyMs))
        case .zoom(let z):
            return ok(await zoom(to: z))
        case .focusBoard:
            return ok(try await focusBoard())
        case .focusTerminal(let card):
            return ok(try await focus(onTerminal: card))
        case .focusMarkdown(let card):
            return ok(try await focus(onDoc: card, clicks: 1, thenDropKeys: true))
        case .focusHTML(let card, let borrow):
            return ok(try await focus(onDoc: card, clicks: borrow ? 2 : 1, thenDropKeys: false))
        case .resize(let card, let from, let to):
            return ok(try await resize(try cardView(card), from: from, to: to))
        case .type(let card, let text):
            return ok(try await type(text, into: try terminal(card)))
        case .key(_, let combo, let stroke):
            return ok(try await key(combo, stroke))
        case .contextMenu(let card):
            return ok(try await contextMenu(in: try terminal(card), card: card))
        }
    }

    private func ok(_ body: JSONValue) -> DevReply {
        DevReply(ok: true, body: body.jsonString)
    }

    // MARK: - snapshot

    private func snapshot(until: String?, timeoutMs: Int?) async throws -> DevReply {
        let wait = try DevSnapshotWait(until: until, timeoutMs: timeoutMs)
        let started = Uptime.nowMs
        while true {
            switch wait.step(snapshot: reader.snapshot(), elapsedMs: Int(Uptime.nowMs - started)) {
            case .reply(let reply): return reply
            case .pollAgain: try await Task.sleep(for: .milliseconds(DevSnapshotWait.pollMs))
            }
        }
    }

    // MARK: - zoom

    private func zoom(to z: Double) async -> JSONValue {
        var viewport = board.viewport
        viewport.zoom = z
        board.setViewport(viewport, commit: true)
        await input.settle()
        return DevSnapshot.zoomReply(observed: board.viewport.zoom)
    }

    // MARK: - focus

    private func focusBoard() async throws -> JSONValue {
        let activated = try await input.takeKey()
        let board = self.board
        let press = DevPointer.boardPress(
            among: input.candidates(on: board, where: { $0 === board }), cards: board.cards.values.map(\.frame)
        )
        try input.click(at: press.point, on: board, by: press.delivery)
        return await focusReply(DevInjection(activated: activated, delivery: press.delivery))
    }

    private func focus(onTerminal termID: String) async throws -> JSONValue {
        let activated = try await input.takeKey()
        let view = try terminal(termID)
        let candidates = input.candidates(on: view, where: { $0 === view }, onLink: view.hasLink(at:))
        let cell = view.cellRect(col: 0, row: 0)?.size ?? .zero
        guard let press = DevPointer.press(among: candidates, last: lastPress[termID], cell: cell) else {
            throw DevError(
                .driverThrew, "every point tried on that terminal is on a link, which a press would open",
                extra: ["card": .string(termID)]
            )
        }
        lastPress[termID] = press.point
        try input.click(at: press.point, on: view, by: press.delivery)
        return await focusReply(DevInjection(activated: activated, delivery: press.delivery))
    }

    /// A markdown card's own press leaves the keys where they were, so its
    /// route also takes them off the terminal — the board is what holds them
    /// when no card does.
    private func focus(onDoc path: String, clicks: Int, thenDropKeys: Bool) async throws -> JSONValue {
        let activated = try await input.takeKey()
        guard let body = board.card(.doc(path))?.docBody else {
            throw DevError(.driverThrew, "no document behind \(path)")
        }
        guard let press = DevPointer.press(among: input.candidates(on: body, where: { $0.isDescendant(of: body) }))
        else { throw DevError(.driverThrew, "\(path) has no body to press") }
        try input.click(at: press.point, on: body, by: press.delivery, count: clicks)
        if thenDropKeys { window.makeFirstResponder(board) }
        return await focusReply(DevInjection(activated: activated, delivery: press.delivery))
    }

    private func focusReply(_ injection: DevInjection) async -> JSONValue {
        await input.settle()
        return injection.annotate(
            DevSnapshot.focusReply(selectedCard: board.selectedID?.wireID, keyboardFocus: reader.keyboardFocus)
        )
    }

    // MARK: - resize

    private func resize(_ card: CardView, from: CGSize, to: CGSize) async throws -> JSONValue {
        let activated = try await input.takeKey()
        guard let cards = card.superview, let grip = card.subviews.lazy.compactMap({ $0 as? CardResizeGrip }).first
        else { throw DevError(.driverThrew, "the card has no resize handle to drag") }
        let delta = DevResizeGrip.delta(from: from, to: to, zoom: board.viewport.zoom)
        let events = try DevResizeGrip.drag(at: DevResizeGrip.handle(of: card.frame), by: delta).map { step in
            try input.mouse(step.phase.eventType, at: cards.convert(step.location, to: nil))
        }
        let delivery = DevPointer.Delivery(
            reachable: events.first.map { input.hitView(at: $0.locationInWindow) === grip } ?? false
        )
        input.deliver(events, to: grip, by: delivery)
        await input.settle()
        return DevInjection(activated: activated, delivery: delivery).annotate(
            DevResizeGrip.reply(from: from, to: card.worldFrame.rect.size, delta: delta)
        )
    }

    // MARK: - type and key

    private func type(_ text: String, into view: TerminalView) async throws -> JSONValue {
        let plan = DevTypePlan.plan(text: text, kittyFlags: view.engine.kittyKeyboardFlags)
        let activated = plan.pressesKeys ? try await input.takeKey() : false
        var inserted: [Bool] = []
        for step in plan.steps {
            switch step {
            case .insert(_, let char): inserted.append(insert(char, into: view))
            case .key(_, _, let stroke): try input.press(stroke)
            case .drop: break
            }
        }
        await input.settle()
        return DevInjection(activated: activated).annotate(DevTypePlan.summary(of: plan, inserted: inserted))
    }

    /// Commits `char` the way an input method does, and says whether the view
    /// sent anything for it: an insertion that leaves no bytes for the PTY is a
    /// dropped character.
    private func insert(_ char: String, into view: TerminalView) -> Bool {
        let forward = view.onInput
        var sent = false
        view.onInput = { bytes in
            sent = true
            forward?(bytes)
        }
        defer { view.onInput = forward }
        view.insertText(char, replacementRange: NSRange(location: NSNotFound, length: 0))
        return sent
    }

    private func key(_ combo: String, _ stroke: DevKeyStroke) async throws -> JSONValue {
        let activated = try await input.takeKey()
        try input.press(stroke)
        await input.settle()
        return DevInjection(activated: activated).annotate(
            DevKeyCombo.reply(combo: combo, events: DevKeyCombo.strokeEvents)
        )
    }

    /// The right-click's own work — selecting the word under it — is done by
    /// `menu(for:)`, which is asked directly: sent as an event, the menu it
    /// returns would be popped up and tracked modally, and nothing could answer.
    /// Asked directly it needs no key window, so the app is not activated.
    private func contextMenu(in view: TerminalView, card: String) async throws -> JSONValue {
        guard let cell = DevCellPoint.lastWrittenCell(in: view.viewportCells()),
              let rect = view.cellRect(col: cell.col, row: cell.row)
        else { throw DevCellPoint.emptyBuffer(card: card) }
        let point = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        guard view.menu(for: try input.mouse(.rightMouseDown, at: point)) != nil else {
            throw DevCellPoint.mouseTracked(card: card)
        }
        await input.settle()
        return DevInjection(activated: false).annotate(
            DevKeyCombo.reply(combo: DevKeyCombo.contextMenu, events: DevKeyCombo.contextMenuEvents)
        )
    }

    // MARK: - targets

    private func cardView(_ id: String) throws -> CardView {
        guard let card = board.cards.values.first(where: { $0.id.wireID == id }) else {
            throw DevError(.driverThrew, "card \(id) left the board mid-verb")
        }
        return card
    }

    private func terminal(_ termID: String) throws -> TerminalView {
        guard let view = controller.sessions[termID]?.view else {
            throw DevError(.driverThrew, "no terminal behind \(termID)")
        }
        return view
    }
}

private extension DevResizeGrip.Phase {
    var eventType: NSEvent.EventType {
        switch self {
        case .press: .leftMouseDown
        case .drag: .leftMouseDragged
        case .release: .leftMouseUp
        }
    }
}
#endif
