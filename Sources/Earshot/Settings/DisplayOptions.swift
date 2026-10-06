import AppKit
import SwiftUI

/// The ways the captions can present the translation stream.
enum DisplayStyle: String, CaseIterable, Identifiable {
    case subtitles
    case teleprompter
    case ticker
    case transcript
    case spotlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtitles: return "Subtitles"
        case .teleprompter: return "Teleprompter"
        case .ticker: return "News Ticker"
        case .transcript: return "Transcript"
        case .spotlight: return "Spotlight"
        }
    }

    var symbol: String {
        switch self {
        case .subtitles: return "captions.bubble"
        case .teleprompter: return "scroll"
        case .ticker: return "text.line.first.and.arrowtriangle.forward"
        case .transcript: return "list.bullet.rectangle"
        case .spotlight: return "quote.bubble"
        }
    }

    var summary: String {
        switch self {
        case .subtitles: return "The latest lines at the bottom, like film subtitles."
        case .teleprompter: return "Large text that scrolls up as the speaker talks."
        case .ticker: return "A single line crawling across a broadcast-style band."
        case .transcript: return "Timestamped history with the original text."
        case .spotlight: return "Only the current sentence, as big as it fits."
        }
    }

    /// How big this style draws text relative to the base font size.
    var fontScale: CGFloat {
        switch self {
        case .subtitles: return 1
        case .teleprompter: return 1.35
        case .ticker: return 0.9
        case .transcript: return 0.62
        case .spotlight: return 1.7
        }
    }
}

enum FontWeightOption: String, CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold, heavy

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var weight: Font.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    /// NSFontManager's 0–15 weight scale.
    var fontManagerWeight: Int {
        switch self {
        case .light: return 3
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 11
        }
    }
}

enum TextAlignmentOption: String, CaseIterable, Identifiable {
    case leading, center, trailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading: return "Left"
        case .center: return "Center"
        case .trailing: return "Right"
        }
    }

    var symbol: String {
        switch self {
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        }
    }

    var text: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// Font families offered in Settings: the system designs first, then everything installed.
enum FontCatalog {
    static let system = "System"
    static let systemRounded = "System Rounded"
    static let systemSerif = "System Serif"
    static let systemMono = "System Monospaced"
    static let systemDesigns = [system, systemRounded, systemSerif, systemMono]

    @MainActor
    static var families: [String] {
        systemDesigns + NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func font(family: String, size: CGFloat, weight: FontWeightOption) -> Font {
        switch family {
        case system: return .system(size: size, weight: weight.weight, design: .default)
        case systemRounded: return .system(size: size, weight: weight.weight, design: .rounded)
        case systemSerif: return .system(size: size, weight: weight.weight, design: .serif)
        case systemMono: return .system(size: size, weight: weight.weight, design: .monospaced)
        default: return .custom(family, size: size).weight(weight.weight)
        }
    }

    @MainActor
    static func nsFont(family: String, size: CGFloat, weight: FontWeightOption) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
        switch family {
        case system:
            return base
        case systemRounded, systemSerif, systemMono:
            let design: NSFontDescriptor.SystemDesign = family == systemRounded ? .rounded : (family == systemSerif ? .serif : .monospaced)
            guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        default:
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: weight.fontManagerWeight, size: size) ?? base
        }
    }
}
