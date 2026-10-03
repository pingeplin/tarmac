import Foundation

/// Magnify (no re-wrap) versus reveal zoom for an HTML card, decided from the
/// document's `<meta name="tarmac-zoom">` (specs 2607.0006, 2609.0003). Every zoom
/// verdict lives here so it stays testable; applying one — the frozen
/// magnification and how the page is told about it — is the view layer's.
public enum ZoomMode: String, Equatable, Sendable {
    case magnify, reveal

    /// Magnify is the DEFAULT: an agent writing a report does not know to ask for a
    /// stable layout, and a document that re-wraps as you zoom is the wrong default
    /// for what most HTML cards are. Only a deliberate, well-formed `reveal` opts
    /// out — the case with a real reason behind it (a self-contained D3/Canvas
    /// dashboard needing honest viewport dimensions, spec 2607.0004 S6) — so a
    /// malformed value takes the default rather than silently landing in the mode
    /// almost nobody wants. The default is decided here, not as markup injected
    /// into the page: that would make the served document lie about its source.
    public static func declared(metaContent: String?) -> ZoomMode {
        metaContent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "reveal" ? .reveal : .magnify
    }

    /// What the host does with one `ready` from a card.
    public struct ReadyActions: Equatable, Sendable {
        /// The mode to adopt for this load, or nil to keep the one in force.
        public var adopt: ZoomMode?
        /// The once-per-load console line, or nil to log nothing.
        public var logLine: String?
        /// Whether to answer this ready with the frozen magnification.
        public var magnify: Bool

        public init(adopt: ZoomMode?, logLine: String?, magnify: Bool) {
            self.adopt = adopt
            self.logLine = logLine
            self.magnify = magnify
        }
    }

    /// A document that reloads ITSELF changes neither its `src` nor its change time,
    /// so the host's per-load state never resets and its `ready` arrives with a
    /// mode already in force (#99). Adopting a mode and logging stay once-per-load —
    /// a forged repeat must not flip the mode out from under the card — while the
    /// magnification answers EVERY ready, which is idempotent because it is a
    /// constant.
    ///
    /// A repeat decides from `inForce`, never from its own `meta`: otherwise a
    /// forged `magnify` would inject magnification into a reveal card.
    ///
    /// - Parameters:
    ///   - inForce: the mode already adopted for THIS load, or nil when no genuine
    ///     ready has been honored yet.
    ///   - meta: this ready's `<meta name="tarmac-zoom">` content (nil = no tag).
    public static func ready(inForce: ZoomMode?, meta: String?) -> ReadyActions {
        let declaredMode = declared(metaContent: meta)
        let effective = inForce ?? declaredMode
        return ReadyActions(
            adopt: inForce == nil ? declaredMode : nil,
            // Keyed on the tag being PRESENT, not on the resolved mode: an empty or
            // malformed content is a tag the author wrote, and only an absent one is
            // silent. The line names the resolved mode, not the raw tag, because its
            // job is to say what is in force for a document whose meta may be a typo.
            logLine: inForce == nil && meta != nil
                ? "zoom-mode declared=\(declaredMode.rawValue) effective=\(declaredMode.rawValue)"
                : nil,
            magnify: effective == .magnify
        )
    }
}
