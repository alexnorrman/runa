import AppKit
import CoreText
import SwiftUI

/// Inter Variable with exact weights (Linear uses 510 and 590, which named weights cannot express).
public enum RunaFont {
    public enum Weight: CGFloat, Sendable {
        case regular = 400
        case medium = 510
        case semibold = 590
        case bold = 680
    }

    nonisolated(unsafe) private static var registered = false
    private static let lock = NSLock()

    /// Registers the bundled font. Safe to call more than once.
    public static func register() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        if let url = Bundle.module.url(forResource: "InterVariable", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    public static func nsFont(size: CGFloat, weight: Weight = .regular) -> NSFont {
        register()
        let wght: UInt32 = 0x7767_6874  // 'wght'
        let opsz: UInt32 = 0x6F70_737A  // 'opsz'
        let attributes: [NSFontDescriptor.AttributeName: Any] = [
            .name: "InterVariable",
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [
                wght: weight.rawValue,
                opsz: min(max(size, 14), 32),
            ],
            .featureSettings: [
                // Tabular numbers keep counts aligned; cv11 is Inter's single-storey a, which Linear uses.
                [NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector],
            ],
        ]
        let descriptor = NSFontDescriptor(fontAttributes: attributes)
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight.appKit)
    }

    public static func font(size: CGFloat, weight: Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight))
    }

    public static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Scale: 12 mini, 13 small, 14 body (desktop), 15/17/20/24 titles.
    public static let mini = font(size: 11.5, weight: .medium)
    public static let small = font(size: 12.5)
    public static let smallMedium = font(size: 12.5, weight: .medium)
    public static let body = font(size: 13.5)
    public static let bodyMedium = font(size: 13.5, weight: .medium)
    public static let title3 = font(size: 15, weight: .semibold)
    public static let title2 = font(size: 18, weight: .semibold)
    public static let title1 = font(size: 24, weight: .semibold)
    public static let keyName = mono(size: 12.5)
}

extension RunaFont.Weight {
    var appKit: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

extension View {
    /// Titles in Linear tighten tracking slightly.
    public func runaTitle(_ font: Font = RunaFont.title2) -> some View {
        self.font(font).tracking(-0.2).foregroundStyle(RunaColor.textPrimary)
    }
}
