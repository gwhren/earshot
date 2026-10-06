// Checks Earshot's caption window from the outside:
//
//   swift Tools/overlay_probe.swift
//
// Prints the window's level and frame. Then, if this terminal is allowed to
// control the computer (System Settings → Privacy & Security → Accessibility),
// it clicks the middle of the captions and checks that the app whose window is
// underneath (which must not already be in front) received the click.
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

func owner(_ window: [String: Any]) -> String { window[kCGWindowOwnerName as String] as? String ?? "" }
func layer(_ window: [String: Any]) -> Int { window[kCGWindowLayer as String] as? Int ?? 0 }
func bounds(_ window: [String: Any]) -> CGRect {
    guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: dictionary) else { return .zero }
    return rect
}

// The status item lives at the same level, so tell them apart by size.
let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
guard let caption = windows.first(where: { owner($0) == "Earshot" && layer($0) == statusLevel && bounds($0).height >= 100 }) else {
    fail("no Earshot caption window at the status-bar level (\(statusLevel)) is on screen")
}
let frame = bounds(caption)
print("Caption window: level \(layer(caption)), frame \(frame)")

guard AXIsProcessTrusted() else {
    print("SKIP click-through check: allow this terminal under Privacy & Security → Accessibility to run it")
    exit(0)
}

let centre = CGPoint(x: frame.midX, y: frame.midY)
guard let below = windows.first(where: { owner($0) != "Earshot" && layer($0) == 0 && bounds($0).contains(centre) }) else {
    fail("put another app's window behind the middle of the captions first")
}
let target = owner(below)
// The caption panel never activates, so the click only proves something if the app
// underneath isn't already in front.
if NSWorkspace.shared.frontmostApplication?.localizedName == target {
    fail("\(target) is already in front; bring another app (this terminal, say) forward, keeping \(target)'s window behind the captions")
}
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: centre, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(50_000)
}
usleep(500_000)
let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
if frontmost == target {
    print("PASS: the click went through the captions to \(target)")
} else {
    fail("the click went to \(frontmost), expected \(target)")
}
