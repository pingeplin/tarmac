/// The lines of a first-visit restore (spec 2611.0011, D13), which the restore
/// card shows (#358). A folder is counted as asked for, not as found: a gone
/// folder gives `$HOME` silently.
public enum RestoreSummary {
    public static func lines(plan: BoardRestore.Plan) -> [String] {
        let spawned = plan.terms.filter(\.needsSpawn)
        let inFolders = spawned.filter { $0.spawn?.cwd != nil }.count
        let resumable = spawned.filter { $0.resume != nil }.count
        var lines: [String] = []
        if inFolders == 1 { lines.append("✓ 1 terminal back in its folder") }
        if inFolders > 1 { lines.append("✓ \(inFolders) terminals back in their folders") }
        if resumable > 0 { lines.append("↻ \(resumable) with an agent session to resume") }
        return lines
    }
}
