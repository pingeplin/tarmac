import Foundation

/// The Dock icon of a dev app (`make run`), which has no bundle and so no icon of
/// its own. A dev app is one with a dev label, the same rule as the title suffix,
/// so the icon and the title never disagree.
public enum DevIcon {
    public static func path(devLabel: String?, iconPath: String?) -> String? {
        guard !WindowTitle.devSuffix(label: devLabel).isEmpty, let iconPath, !iconPath.isEmpty else { return nil }
        return iconPath
    }
}
