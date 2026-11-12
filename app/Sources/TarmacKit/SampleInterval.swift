import Foundation

/// How often the app writes a sample line (spec 2611.0004): every 300 s. The
/// override is the DEBUG-only `TARMAC_SAMPLE_INTERVAL_S`, read by the app; a
/// release build never passes one.
public enum SampleInterval {
    public static let defaultSeconds: TimeInterval = 300

    /// A number of seconds, at least 1, replaces the default; anything else
    /// is ignored.
    public static func seconds(override: String?) -> TimeInterval {
        guard let value = override.flatMap(Double.init), value.isFinite, value >= 1 else { return defaultSeconds }
        return value
    }
}
