import Foundation

/// One theme's colours as 0xRRGGBB values. Views map them to SwiftUI colours;
/// keeping them as plain numbers lets tests check contrast without a UI.
public struct ThemePalette: Sendable, Equatable {
    public let background: UInt32
    /// The Chats column, one step off `background`.
    public let sidebar: UInt32
    public let agentBubble: UInt32
    public let userBubble: UInt32
    public let primaryText: UInt32
    public let secondaryText: UInt32
    public let separator: UInt32
    public let accent: UInt32
    public let codeBackground: UInt32
    public let keyword: UInt32
    public let string: UInt32
    public let number: UInt32
    public let comment: UInt32
    public let type: UInt32
    public let function: UInt32
    public let punctuation: UInt32

    /// The syntax colour for a role. Attributes share the function colour.
    public func color(for role: SyntaxRole) -> UInt32 {
        switch role {
        case .keyword: keyword
        case .string: string
        case .number: number
        case .comment: comment
        case .type: type
        case .function, .attribute: function
        case .punctuation: punctuation
        }
    }
}

/// A photo drawn once behind the conversation, under a flat scrim of the
/// theme's `background` so text on it keeps its contrast.
public struct ThemeBackground: Sendable, Equatable {
    public let asset: String
    /// Opacity of the scrim over the image, 0...1.
    public let scrim: Double
    /// Darkest and lightest greyscale values (0...255) measured in the image.
    public let pixelRange: ClosedRange<Double>
}

public enum ThemeScheme: Sendable, Equatable {
    /// Follows the device: both palettes are declared.
    case system, dark, light
}

public struct WonderThemeSpec: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let scheme: ThemeScheme
    let light: ThemePalette?
    let dark: ThemePalette?
    public let background: ThemeBackground?

    /// The palette to draw with; `systemIsDark` only matters for `.system`.
    public func palette(systemIsDark: Bool) -> ThemePalette {
        switch scheme {
        case .dark: dark ?? light!
        case .light: light ?? dark!
        case .system: systemIsDark ? dark! : light!
        }
    }

    /// The appearance to force, or nil to follow the device.
    public var forcedDark: Bool? {
        switch scheme {
        case .system: nil
        case .dark: true
        case .light: false
        }
    }
}

public enum WonderThemeCatalog {
    public static let defaultID = "wonder"

    /// The default "Wonder" theme first, then classic palettes, then photos.
    public static var themes: [WonderThemeSpec] { all }

    /// A stored id that no longer exists falls back to Wonder.
    public static func theme(id: String?) -> WonderThemeSpec {
        all.first { $0.id == id } ?? all[0]
    }
}

/// WCAG 2 relative luminance and contrast ratio for 0xRRGGBB colours.
public enum ThemeContrast {
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    /// Contrast of `foreground` over `background` shown through a scrim of
    /// `scrim` opacity on a pixel of the given 0...255 brightness.
    public static func worstCaseRatio(foreground: UInt32, scrimColor: UInt32, scrim: Double, pixelValue: Double) -> Double {
        func blend(_ shift: UInt32) -> Double {
            let s = Double((scrimColor >> shift) & 0xFF)
            return s * scrim + pixelValue * (1 - scrim)
        }
        let r = UInt32(blend(16).rounded()), g = UInt32(blend(8).rounded()), b = UInt32(blend(0).rounded())
        return ratio(foreground, (r << 16) | (g << 8) | b)
    }
}
