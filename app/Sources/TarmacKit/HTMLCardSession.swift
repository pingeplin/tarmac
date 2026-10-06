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
        case .shown:
            return [.documentShown]
        case .ready(let meta):
            // A document is born not knowing whether its card is culled, and a
            // message sent before it committed went to the page it replaced.
            var effects: [Effect] = [.post(.cull(culled))]
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

    /// The document was loaded again from disk: its mode is decided afresh, so
    /// a meta tag that was removed does not carry over. The console is kept.
    public mutating func reloaded() {
        mode = nil
    }
}
