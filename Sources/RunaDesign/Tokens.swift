import AppKit
import SwiftUI

extension Color {
    /// A color that resolves differently in light and dark appearance.
    public init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Runa's color tokens. Dark is the primary design; light is fully supported.
public enum RunaColor {
    public static let appBackground = Color(light: 0xFFFFFF, dark: 0x08090A)
    public static let panel = Color(light: 0xF7F8F8, dark: 0x0F1011)
    public static let elevated = Color(light: 0xFFFFFF, dark: 0x161718)
    public static let hover = Color(light: 0xF0F1F3, dark: 0x191A1B)
    public static let selected = Color(light: 0x5E6AD2, dark: 0x5E6AD2, lightAlpha: 0.10, darkAlpha: 0.16)

    public static let textPrimary = Color(light: 0x0F1011, dark: 0xF7F8F8)
    public static let textSecondary = Color(light: 0x3C3F44, dark: 0xD0D6E0)
    public static let textTertiary = Color(light: 0x6F737A, dark: 0x8A8F98)
    public static let textQuaternary = Color(light: 0x9A9EA5, dark: 0x5E626A)

    public static let borderSubtle = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.07)
    public static let borderStrong = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.12)

    public static let accent = Color(hex: 0x5E6AD2)
    public static let accentHover = Color(hex: 0x6E79D6)
    public static let onAccent = Color.white

    public static let missing = Color(light: 0xD94848, dark: 0xEB5757)
    public static let machine = Color(light: 0x8B6CF0, dark: 0xB59AFF)
    public static let review = Color(light: 0xD9A514, dark: 0xF2C94C)
    public static let approved = Color(light: 0x3A9C6C, dark: 0x4CB782)
}

public enum RunaSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum RunaRadius {
    public static let chip: CGFloat = 4
    public static let control: CGFloat = 6
    public static let card: CGFloat = 8
    public static let sheet: CGFloat = 12
}

public enum RunaMotion {
    public static let quick = Animation.easeOut(duration: 0.12)
    public static let standard = Animation.easeOut(duration: 0.18)
}
