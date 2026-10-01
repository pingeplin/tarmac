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

    init(controller: AppController, quitGuard: QuitGuardController, window: NSWindow) {
        self.controller = controller
        self.quitGuard = quitGuard
        self.window = window
    }

    var input: DevInput { DevInput(window: window) }
    private var reader: DevSnapshotReader { DevSnapshotReader(controller: controller, quitGuard: quitGuard) }
    private var board: BoardView { controller.activeBoard.view }

    func answer(_ request: DevRequest) async -> DevReply {
        // A board that is being switched away from is out of the window for a moment.
        guard board.window === window else {
            return DevError(.appNotReady, "no board is on screen yet").reply
        }
        do {
            return try await run(DevRouting.route(request, in: reader.routingContext))
        } catch let error as DevError {
            return error.reply
        } catch {
            return DevError(.driverThrew, "\(error)").reply
        }
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
            return ok(try await focus(on: try terminal(card), card: card))
        case .focusMarkdown(let card):
            return ok(try await focus(on: try docBody(card), card: card, thenDropKeys: true))
        case .focusHTML(let card, let borrow):
            return ok(try await focus(on: try docBody(card), card: card, clicks: borrow ? 2 : 1))
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
        _ = try await input.takeKey()
        let board = self.board
        guard let point = input.point(on: board, where: { $0 === board }) else {
            throw DevError(.driverThrew, "no empty board space is on screen to press")
        }
        try input.click(at: point)
        return await focusReply()
    }

    /// A press on the card's body. A markdown card's own press leaves the keys
    /// where they were, so its route also takes them off the terminal — the
    /// board is what holds them when no card does.
    private func focus(
        on body: NSView, card: String, clicks: Int = 1, thenDropKeys: Bool = false
    ) async throws -> JSONValue {
        _ = try await input.takeKey()
        guard let point = input.point(on: body, where: { $0.isDescendant(of: body) }) else {
            throw DevError(
                .cardHidden,
                "that card's body is off screen or under another view, where a press cannot reach it; "
                    + "zoom out (or pan by hand — no verb pans)",
                extra: ["card": .string(card)]
            )
        }
        try input.click(at: point, count: clicks)
        if thenDropKeys { window.makeFirstResponder(board) }
        return await focusReply()
    }

    private func focusReply() async -> JSONValue {
        await input.settle()
        return DevSnapshot.focusReply(selectedCard: board.selectedID?.wireID, keyboardFocus: reader.keyboardFocus)
    }

    // MARK: - resize

    private func resize(_ card: CardView, from: CGSize, to: CGSize) async throws -> JSONValue {
        _ = try await input.takeKey()
        guard let cards = card.superview else { throw DevError(.driverThrew, "the card left the board mid-verb") }
        let delta = DevResizeGrip.delta(from: from, to: to, zoom: board.viewport.zoom)
        let events = try DevResizeGrip.drag(at: DevResizeGrip.handle(of: card.frame), by: delta).map { step in
            try input.mouse(step.phase.eventType, at: cards.convert(step.location, to: nil))
        }
        try drag(events, onGripOf: card)
        await input.settle()
        return DevResizeGrip.reply(from: from, to: card.worldFrame.rect.size, delta: delta)
    }

    /// A press is hit-tested, so it reaches the handle only where the handle is
    /// on screen with nothing over it. A card is often larger than the window
    /// leaves room for, and its corner is then outside it; the same events are
    /// handed to the handle itself there, which runs the whole gesture but not
    /// the window's own handling of a press.
    private func drag(_ events: [NSEvent], onGripOf card: CardView) throws {
        guard let press = events.first else { return }
        if let hit = input.hitView(at: press.locationInWindow) as? CardResizeGrip, hit.superview === card {
            events.forEach(input.send)
            return
        }
        guard let grip = card.subviews.lazy.compactMap({ $0 as? CardResizeGrip }).first else {
            throw DevError(.driverThrew, "the card has no resize handle")
        }
        FileHandle.standardError.write(Data(
            "tarmac: dev resize: \(card.id.wireID)'s handle is off screen or covered; dragging it directly\n".utf8
        ))
        for event in events {
            switch event.type {
            case .leftMouseDown: grip.mouseDown(with: event)
            case .leftMouseDragged: grip.mouseDragged(with: event)
            default: grip.mouseUp(with: event)
            }
        }
    }

    // MARK: - type and key

    private func type(_ text: String, into view: TerminalView) async throws -> JSONValue {
        _ = try await input.takeKey()
        let plan = DevTypePlan.plan(text: text, kittyFlags: view.engine.kittyKeyboardFlags)
        var inserted: [Bool] = []
        for step in plan.steps {
            switch step {
            case .insert(_, let char): inserted.append(insert(char, into: view))
            case .key(_, _, let stroke): try input.press(stroke)
            case .drop: break
            }
        }
        await input.settle()
        return DevTypePlan.summary(of: plan, inserted: inserted)
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
        _ = try await input.takeKey()
        try input.press(stroke)
        await input.settle()
        return DevKeyCombo.reply(combo: combo, events: DevKeyCombo.strokeEvents)
    }

    /// The right-click's own work — selecting the word under it — is done by
    /// `menu(for:)`, which is asked directly: sent as an event, the menu it
    /// returns would be popped up and tracked modally, and nothing could answer.
    private func contextMenu(in view: TerminalView, card: String) async throws -> JSONValue {
        _ = try await input.takeKey()
        guard let cell = DevCellPoint.lastWrittenCell(in: view.viewportCells()),
              let rect = view.cellRect(col: cell.col, row: cell.row)
        else { throw DevCellPoint.emptyBuffer(card: card) }
        let point = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        guard view.menu(for: try input.mouse(.rightMouseDown, at: point)) != nil else {
            throw DevCellPoint.mouseTracked(card: card)
        }
        await input.settle()
        return DevKeyCombo.reply(combo: DevKeyCombo.contextMenu, events: DevKeyCombo.contextMenuEvents)
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

    private func docBody(_ path: String) throws -> NSView {
        guard let body = board.card(.doc(path))?.docView else {
            throw DevError(.driverThrew, "no document behind \(path)")
        }
        return body
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
