import AppKit
import Carbon.HIToolbox

/// Shortcuts that work from any app. They all use ⌃⌥⌘ because window managers
/// such as Rectangle take many of the ⌃⌥ combinations.
enum GlobalShortcut: UInt32, CaseIterable, Identifiable {
    case toggleListening = 1
    case toggleCaptions
    case biggerText
    case smallerText

    static let modifierFlags: NSEvent.ModifierFlags = [.control, .option, .command]
    static let carbonModifiers = UInt32(controlKey | optionKey | cmdKey)

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .toggleListening: return "Start or stop listening"
        case .toggleCaptions: return "Show or hide captions"
        case .biggerText: return "Bigger text"
        case .smallerText: return "Smaller text"
        }
    }

    /// The key as `NSMenuItem.keyEquivalent` spells it.
    var key: String {
        switch self {
        case .toggleListening: return "l"
        case .toggleCaptions: return "c"
        case .biggerText: return "="
        case .smallerText: return "-"
        }
    }

    /// Carbon virtual key code (the key's position on a US keyboard).
    var keyCode: UInt32 {
        switch self {
        case .toggleListening: return UInt32(kVK_ANSI_L)
        case .toggleCaptions: return UInt32(kVK_ANSI_C)
        case .biggerText: return UInt32(kVK_ANSI_Equal)
        case .smallerText: return UInt32(kVK_ANSI_Minus)
        }
    }

    /// "⌃⌥⌘L"
    var displayString: String {
        "⌃⌥⌘" + key.uppercased()
    }

    /// Shows the shortcut beside a menu item.
    func apply(to item: NSMenuItem) {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = Self.modifierFlags
    }
}
