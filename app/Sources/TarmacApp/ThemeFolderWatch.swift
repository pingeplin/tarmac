import CoreServices
import Foundation

/// Tells of each change of one folder, for as long as it lives (spec
/// 2610.0009): a file added, removed, renamed, replaced or changed in place,
/// and the folder itself made, removed or renamed.
///
/// It decides nothing, and reads no path and no flag of an event: the flags
/// are a history and not a kind, and for a folder that is a link the paths
/// are the real ones. The stream is on the path, not on an open folder, so it
/// can start before the folder is there and goes on after the folder was
/// removed and made again. A file outside the folder that a link in it names
/// is not watched.
///
/// Unchecked: both members are set in `init` and never again, and the stream
/// tells on the main queue.
final class ThemeFolderWatch: @unchecked Sendable {
    /// What the system waits for more changes before it tells: one save by
    /// an editor is one report, not a report for each of its steps.
    private static let latency: CFTimeInterval = 0.2

    private let changed: @MainActor () -> Void
    private var stream: FSEventStreamRef?

    init(path: String, changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil
        )
        // The stream is on the main queue.
        let told: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watch = Unmanaged<ThemeFolderWatch>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watch.changed() }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        stream = FSEventStreamCreate(
            nil, told, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency, FSEventStreamCreateFlags(flags)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
