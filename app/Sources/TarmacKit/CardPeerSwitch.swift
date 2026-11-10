/// WebKit's own switch for WebRTC, which an HTML card's web view turns off
/// where the system has it. The shim removes the interfaces either way
/// (`card_shim.js`); the switch is the engine saying the same.
public enum CardPeerSwitch {
    /// What to log, or nil when the switch is in force. `enabled` is what the
    /// switch reads after it was turned off, nil on a system that has none.
    public static func logLine(readback enabled: Bool?) -> String? {
        enabled == false
            ? nil : "HTML cards: the PeerConnectionEnabled switch is not in force; the shim alone removes WebRTC"
    }
}
