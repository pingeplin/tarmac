/// The version this app names in `hello.app_version`, and compares against
/// `hello_ok.daemon_version` to spot a stale daemon (`DaemonLaunch.shouldRestart`).
///
/// It has to be the daemon's `CARGO_PKG_VERSION` string exactly, so it is never
/// guessed: a bundle carries it in `CFBundleShortVersionString`, an unbundled
/// dev binary is told it through the environment, and an app that has neither
/// names no version — which also means it never restarts a daemon.
public enum AppVersion {
    public static let environmentKey = "TARMAC_APP_VERSION"

    public static func resolve(bundleShortVersion: String?, env: [String: String]) -> String? {
        if let bundleShortVersion, !bundleShortVersion.isEmpty { return bundleShortVersion }
        if let named = env[environmentKey], !named.isEmpty { return named }
        return nil
    }
}
