/// How long a QA-driver verb that dispatched input waits before it builds its
/// reply (spec 2609.0015, issue #166): two display frames, so the reply
/// describes what the input produced, or the cap, whichever comes first. A
/// hidden or miniaturized window services no frames at all, and the cap is what
/// keeps the driver usable there.
public enum DevSettle {
    public static let frames = 2
    public static let capMs = 100

    public static func isSettled(framesSeen: Int, elapsedMs: Int) -> Bool {
        framesSeen >= frames || elapsedMs >= capMs
    }
}
