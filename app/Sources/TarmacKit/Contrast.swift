import Foundation

/// How far apart two colours are for the eye (spec 2610.0007): what the tests
/// of a palette measure with.
public enum Contrast {
    /// The WCAG 2 contrast ratio of two sRGB colours, 1 to 21.
    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (first, second) = (luminance(a), luminance(b))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// The WCAG 2 relative luminance of `0xRRGGBB`, 0 to 1.
    private static func luminance(_ rgb: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double(rgb >> shift & 0xff) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}
