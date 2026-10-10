/// One HTML card's host-side state: its console, the zoom mode its current
/// document load is in, and whether it is culled. The view applies the effects
/// in the order given.
public struct HTMLCardSession: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        case post(CardHostMessage)
        /// Un-borrow the card and give the keyboard back to the prime terminal.
        case escapeHome
        case consoleChanged
        case modeChanged
        case scrollChanged(ScrollMetrics)
        /// The document is on screen: the web view can be seen.
        case documentShown
    }

    public private(set) var console = CardConsole.Buffer()
    /// The mode adopted for the current load; nil until its first ready.
    public private(set) var mode: ZoomMode?
    public var culled = false
    /// The number of the load the frame was last given; 0 before the first.
    private var load = 0
    /// The fonts last given. A reload keeps them: the next document is born
    /// with the values of its request, which a change since then missed.
    private var fonts: CardFontVariables?

    public init() {}

    public mutating func handle(_ message: CardConsole.Message, borrowed: Bool) -> [Effect] {
        switch message {
        case .escape:
            return borrowed ? [.escapeHome] : []
        case .console(let entry):
            console.push(entry)
            return [.consoleChanged]
        case .scrolled(let metrics):
            return [.scrollChanged(metrics)]
        case .shown(let load):
            // The word for a load that was replaced on its way here: the view
            // is covered again, for a document that is not on screen yet.
            return load == self.load ? [.documentShown] : []
        case .ready(let meta):
            // A document is born not knowing whether its card is culled, and a
            // message sent before it committed went to the page it replaced.
            var effects: [Effect] = [.post(.cull(culled))]
            if let fonts { effects.append(.post(.fonts(fonts))) }
            let actions = ZoomMode.ready(inForce: mode, meta: meta)
            if actions.magnify { effects.append(.post(.zoom(Double(CardZoom.magnifyK)))) }
            if let line = actions.logLine {
                console.push(CardConsole.Entry(level: .info, args: [.string(line)]))
                effects.append(.consoleChanged)
            }
            if let adopted = actions.adopt {
                mode = adopted
                effects.append(.modeChanged)
            }
            return effects
        }
    }

    /// The message to post, or nil when `fonts` is what the document has.
    public mutating func fontsChanged(_ fonts: CardFontVariables) -> CardHostMessage? {
        guard fonts != self.fonts else { return nil }
        self.fonts = fonts
        return .fonts(fonts)
    }

    /// The document was loaded again from disk: its mode is decided afresh, so
    /// a meta tag that was removed does not carry over. The console is kept.
    /// The result numbers the load, for the host page to name in its `shown`.
    @discardableResult
    public mutating func reloaded() -> Int {
        mode = nil
        load += 1
        return load
    }
}
