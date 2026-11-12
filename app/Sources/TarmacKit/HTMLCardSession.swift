/// One HTML card's host-side state: its console, the zoom mode its current
/// document load is in, whether it is culled, and its data file (spec
/// 2611.0002): which file the current load names, and when to read it and
/// deliver what was read. The view applies the effects in the order given.
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
        /// The data file this card now reads, nil for none: the daemon is to
        /// be told, also when it is the file it was told before.
        case dataFile(String?)
        /// Run this read off the main thread and hand its outcome back
        /// (`readEnded`).
        case read(DataRead)
        /// Hand the data file's text to the document.
        case deliver(String)
    }

    /// A read of `file`, the data file of the card whose file is `html`.
    public struct DataRead: Equatable, Sendable {
        public let file: String
        public let html: String
        let load: Int
    }

    public private(set) var console = CardConsole.Buffer()
    /// The mode adopted for the current load; nil until its first ready.
    public private(set) var mode: ZoomMode?
    private var culled = false
    private var loads = LoadCount()
    /// The fonts last given. A reload keeps them: the next document is born
    /// with the values of its request, which a change since then missed.
    private var fonts: CardFontVariables?
    private let html: String
    private var feed = Feed()
    /// The load whose stamped ready was heard.
    private var namedLoad: Int?
    /// The data line last written, until any other entry or a delivery.
    private var lastDataLine: String?

    /// `html` is the card's file, an absolute and resolved path.
    public init(html: String) {
        self.html = html
    }

    public mutating func handle(_ message: CardConsole.Message, borrowed: Bool) -> [Effect] {
        switch message {
        case .escape:
            return borrowed ? [.escapeHome] : []
        case .console(let entry):
            log(entry)
            return [.consoleChanged]
        case .scrolled(let metrics):
            return [.scrollChanged(metrics)]
        case .shown(let load):
            // The word for a load that was replaced on its way here: the view
            // is covered again, for a document that is not on screen yet.
            return loads.isCurrent(load) ? [.documentShown] : []
        case .ready(let meta, let data, let load):
            // A document is born not knowing whether its card is culled, and a
            // message sent before it committed went to the page it replaced.
            var effects: [Effect] = [.post(.cull(culled))]
            if let fonts { effects.append(.post(.fonts(fonts))) }
            let actions = ZoomMode.ready(inForce: mode, meta: meta)
            if actions.magnify { effects.append(.post(.zoom(Double(CardZoom.magnifyK)))) }
            if let line = actions.logLine {
                log(CardConsole.Entry(level: .info, args: [.string(line)]))
                effects.append(.consoleChanged)
            }
            if let adopted = actions.adopt {
                mode = adopted
                effects.append(.modeChanged)
            }
            // Only the first ready of the current load names the data file:
            // one document cannot register file after file. The host page
            // stamps one for each load, and this does not rest on it.
            if let load, loads.isCurrent(load), load != namedLoad {
                namedLoad = load
                effects += named(data, by: load)
            }
            return effects
        }
    }

    private mutating func named(_ name: String?, by load: Int) -> [Effect] {
        var effects: [Effect] = []
        var file: String?
        if let name {
            switch CardDataPath.dataFile(html: html, name: name) {
            case .file(let path):
                file = path
            case .refused(let path, let reason):
                effects += dataLine(path, reason)
            }
        }
        guard file != nil || feed.file != nil else { return effects }
        feed.register(file, by: load)
        return effects + [.dataFile(file)]
    }

    /// The card was culled, or is back in view: the document is told, and a
    /// read that the cull held back starts.
    public mutating func setCulled(_ culled: Bool) -> [Effect] {
        self.culled = culled
        return [.post(.cull(culled))] + nextRead()
    }

    /// The data file changed on disk.
    public mutating func dataChanged() -> [Effect] {
        feed.changed()
        return nextRead()
    }

    /// A read the view ran has ended. Its text is delivered only to the load
    /// and the file it was started for, and only in view: a card culled
    /// meanwhile reads again when it is back. A change that came during the
    /// read starts the next one, whatever became of this one.
    public mutating func readEnded(_ read: DataRead, _ outcome: CardDataRead.Outcome) -> [Effect] {
        let effects = taken(read, outcome)
        return effects + nextRead()
    }

    /// One read at a time, and none while culled.
    private mutating func nextRead() -> [Effect] {
        feed.next(html: html, loads: loads, culled: culled).map { [.read($0)] } ?? []
    }

    private mutating func taken(_ read: DataRead, _ outcome: CardDataRead.Outcome) -> [Effect] {
        guard feed.ended(read, loads: loads, culled: culled) else { return [] }
        switch outcome {
        case .text(let text):
            lastDataLine = nil
            return [.deliver(text)]
        case .refused(let reason):
            return dataLine(read.file, reason)
        }
    }

    private mutating func log(_ entry: CardConsole.Entry) {
        console.push(entry)
        lastDataLine = nil
    }

    /// The same line twice in a row is written once. The console is kept
    /// across reloads, and so is this.
    private mutating func dataLine(_ path: String, _ reason: String) -> [Effect] {
        let line = "tarmac-data: \(path): \(reason)"
        guard line != lastDataLine else { return [] }
        console.push(CardConsole.Entry(level: .error, args: [.string(line)]))
        lastDataLine = line
        return [.consoleChanged]
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
        return loads.next()
    }
}

/// The card's data file and its reads. A read is for the file and the load
/// that named it, and only while that load is the current one.
private struct Feed: Equatable, Sendable {
    /// What the daemon was last told this card reads; a reload keeps it.
    private(set) var file: String?
    /// The load whose first ready named `file`.
    private var registeredLoad: Int?
    private var reading = false
    private var again = false

    /// A change seen before is not this registration's: the daemon reports
    /// the file anew in answer to each one.
    mutating func register(_ file: String?, by load: Int) {
        self.file = file
        registeredLoad = load
        again = false
    }

    mutating func changed() {
        if file != nil { again = true }
    }

    mutating func next(html: String, loads: LoadCount, culled: Bool) -> HTMLCardSession.DataRead? {
        guard let file, let registeredLoad, loads.isCurrent(registeredLoad), !culled, !reading, again else { return nil }
        reading = true
        again = false
        return HTMLCardSession.DataRead(file: file, html: html, load: registeredLoad)
    }

    /// Whether the read's outcome is the card's to take now.
    mutating func ended(_ read: HTMLCardSession.DataRead, loads: LoadCount, culled: Bool) -> Bool {
        reading = false
        guard loads.isCurrent(read.load) else { return false }
        if culled { again = true }
        return !culled
    }
}
