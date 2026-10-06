import AppKit
import SwiftUI

enum ThemeID: String, CaseIterable, Identifiable {
    case midnight, glass, paper, broadcast, cinema, shadow, terminal, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .midnight: return "Midnight"
        case .glass: return "Glass"
        case .paper: return "Paper"
        case .broadcast: return "Broadcast"
        case .cinema: return "Cinema"
        case .shadow: return "Shadow"
        case .terminal: return "Terminal"
        case .custom: return "Custom"
        }
    }
}

/// Colours and effects for one look.
struct Theme: Equatable {
    var text: Color
    var secondaryText: Color
    var background: Color
    var accent: Color
    /// Band behind the news ticker.
    var band: Color
    /// The "LIVE" badge.
    var badge: Color
    /// Blur whatever is behind the captions.
    var usesMaterial: Bool
    /// Outline text so it stays readable over video.
    var textShadow: Bool
    var isDark: Bool
    /// Nothing but the text and its shadow: no backdrop, column labels, divider, ticker
    /// bands, badges or capsules, and no window shadow.
    var bare = false

    static func preset(_ id: ThemeID, customText: Color, customBackground: Color, customAccent: Color) -> Theme {
        switch id {
        case .midnight:
            return Theme(
                text: .white,
                secondaryText: Color.white.opacity(0.62),
                background: Color(.sRGB, red: 0.07, green: 0.08, blue: 0.10, opacity: 1),
                accent: Color(.sRGB, red: 0.38, green: 0.64, blue: 1.0, opacity: 1),
                band: Color(.sRGB, red: 0.11, green: 0.13, blue: 0.17, opacity: 1),
                badge: Color(.sRGB, red: 0.90, green: 0.16, blue: 0.20, opacity: 1),
                usesMaterial: false, textShadow: false, isDark: true
            )
        case .glass:
            return Theme(
                text: .white,
                secondaryText: Color.white.opacity(0.72),
                background: Color.black,
                accent: Color(.sRGB, red: 0.55, green: 0.85, blue: 1.0, opacity: 1),
                band: Color.black.opacity(0.35),
                badge: Color(.sRGB, red: 0.95, green: 0.25, blue: 0.30, opacity: 1),
                usesMaterial: true, textShadow: true, isDark: true
            )
        case .paper:
            return Theme(
                text: Color(.sRGB, red: 0.12, green: 0.12, blue: 0.13, opacity: 1),
                secondaryText: Color(.sRGB, red: 0.42, green: 0.40, blue: 0.38, opacity: 1),
                background: Color(.sRGB, red: 0.98, green: 0.97, blue: 0.94, opacity: 1),
                accent: Color(.sRGB, red: 0.78, green: 0.33, blue: 0.10, opacity: 1),
                band: Color(.sRGB, red: 0.93, green: 0.91, blue: 0.86, opacity: 1),
                badge: Color(.sRGB, red: 0.80, green: 0.20, blue: 0.15, opacity: 1),
                usesMaterial: false, textShadow: false, isDark: false
            )
        case .broadcast:
            return Theme(
                text: .white,
                secondaryText: Color(.sRGB, red: 0.78, green: 0.84, blue: 1.0, opacity: 1),
                background: Color(.sRGB, red: 0.03, green: 0.12, blue: 0.32, opacity: 1),
                accent: Color(.sRGB, red: 1.0, green: 0.80, blue: 0.10, opacity: 1),
                band: Color(.sRGB, red: 0.02, green: 0.08, blue: 0.24, opacity: 1),
                badge: Color(.sRGB, red: 0.86, green: 0.04, blue: 0.10, opacity: 1),
                usesMaterial: false, textShadow: false, isDark: true
            )
        case .cinema:
            return Theme(
                text: Color(.sRGB, red: 1.0, green: 0.88, blue: 0.12, opacity: 1),
                secondaryText: Color.white.opacity(0.85),
                background: Color.black,
                accent: Color(.sRGB, red: 1.0, green: 0.88, blue: 0.12, opacity: 1),
                band: Color.black,
                badge: Color(.sRGB, red: 0.90, green: 0.12, blue: 0.12, opacity: 1),
                usesMaterial: false, textShadow: true, isDark: true
            )
        case .shadow:
            return Theme(
                text: .white,
                secondaryText: Color.white.opacity(0.75),
                background: .clear,
                // Shows on light and dark slides alike (Move & Resize outline, level bars, ticker dots).
                accent: Color(.sRGB, red: 0.38, green: 0.64, blue: 1.0, opacity: 1),
                band: .clear,
                badge: Color(.sRGB, red: 0.90, green: 0.16, blue: 0.20, opacity: 1),
                usesMaterial: false, textShadow: true, isDark: true, bare: true
            )
        case .terminal:
            return Theme(
                text: Color(.sRGB, red: 0.30, green: 1.0, blue: 0.48, opacity: 1),
                secondaryText: Color(.sRGB, red: 0.20, green: 0.65, blue: 0.34, opacity: 1),
                background: Color(.sRGB, red: 0.02, green: 0.04, blue: 0.02, opacity: 1),
                accent: Color(.sRGB, red: 0.30, green: 1.0, blue: 0.48, opacity: 1),
                band: Color(.sRGB, red: 0.03, green: 0.09, blue: 0.04, opacity: 1),
                badge: Color(.sRGB, red: 0.10, green: 0.55, blue: 0.22, opacity: 1),
                usesMaterial: false, textShadow: false, isDark: true
            )
        case .custom:
            let dark = customBackground.luminance < 0.5
            return Theme(
                text: customText,
                secondaryText: customText.opacity(0.65),
                background: customBackground,
                accent: customAccent,
                band: customBackground.opacity(0.9),
                badge: customAccent,
                usesMaterial: false, textShadow: false, isDark: dark
            )
        }
    }
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
        let hasAlpha = value.count == 8
        let red = Double((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(number & 0xFF) / 255 : 1
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    /// Relative luminance, 0 (black) … 1 (white).
    var luminance: Double {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}
