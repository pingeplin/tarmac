/// The repo dot in a doc card's header. A doc has one only when the daemon
/// gave it a repo colour; the colour is that index wrapped onto the palette.
public enum RepoDot {
    public static func paletteIndex(repoColor: Int?, paletteSize: Int) -> Int? {
        guard let repoColor, repoColor >= 0, paletteSize > 0 else { return nil }
        return repoColor % paletteSize
    }
}
