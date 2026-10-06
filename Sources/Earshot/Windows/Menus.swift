import AppKit
import Combine
import EarshotCore

/// Builds the menu-bar icon's menu, which holds every control.
@MainActor
final class QuickMenuBuilder {
    private weak var delegate: AppDelegate?
    private let model: AppModel
    private let settings: AppSettings
    private let hotKeys: HotKeyCenter

    /// Offered first in the language menus; the full lists live in Settings.
    private let favouriteLanguages = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh-Hans", "ar", "hi", "ru", "uk"]

    init(delegate: AppDelegate, model: AppModel, settings: AppSettings, hotKeys: HotKeyCenter) {
        self.delegate = delegate
        self.model = model
        self.settings = settings
        self.hotKeys = hotKeys
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let banner = model.banner {
            addBanner(banner, to: menu)
        }
        menu.addItem(.separator())

        menu.addItem(shortcut(.toggleListening, on: item(model.isListening ? "Stop Listening" : "Start Listening", #selector(AppDelegate.toggleListening(_:)))))
        let captions = shortcut(.toggleCaptions, on: item("Show Captions", #selector(AppDelegate.toggleCaptions(_:))))
        captions.state = model.captionsVisible ? .on : .off
        menu.addItem(captions)
        menu.addItem(item("Move & Resize Captions…", #selector(AppDelegate.adjustCaptions(_:))))
        menu.addItem(.separator())

        menu.addItem(submenu("Languages", languagesMenu()))
        menu.addItem(submenu("Display Style", displayStyleMenu()))
        menu.addItem(shortcut(.biggerText, on: item("Bigger Text", #selector(AppDelegate.increaseTextSize(_:)))))
        menu.addItem(shortcut(.smallerText, on: item("Smaller Text", #selector(AppDelegate.decreaseTextSize(_:)))))
        menu.addItem(.separator())

        menu.addItem(item("Copy Transcript", #selector(AppDelegate.copyTranscript(_:))))
        menu.addItem(submenu("Export Transcript", exportMenu()))
        menu.addItem(item("Clear Transcript", #selector(AppDelegate.clearTranscript(_:))))
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:))))
        let quit = NSMenuItem(title: "Quit Earshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private var statusLine: String {
        let pair = settings.languagePairLabel
        guard model.isListening else { return "Paused · \(pair)" }
        if model.backlog > 0 { return "Translating (\(model.backlog) waiting) · \(pair)" }
        return (model.isSpeaking ? "Hearing speech · " : "Listening · ") + pair
    }

    // MARK: Sections

    /// The problem, its fix (Retry, Open Settings…) and a way to dismiss it.
    private func addBanner(_ banner: Banner, to menu: NSMenu) {
        let message = NSMenuItem(title: Self.shortened(banner.message), action: nil, keyEquivalent: "")
        message.isEnabled = false
        message.toolTip = banner.message
        message.image = NSImage(systemSymbolName: banner.kind.symbol, accessibilityDescription: nil)
        menu.addItem(message)
        if let action = banner.action {
            menu.addItem(item(action.title, #selector(AppDelegate.performBannerAction(_:))))
        }
        menu.addItem(item("Dismiss", #selector(AppDelegate.dismissBanner(_:))))
    }

    /// Menu items don't wrap, so long messages are cut short; the tooltip has the rest.
    static func shortened(_ text: String, limit: Int = 90) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private func languagesMenu() -> NSMenu {
        let menu = NSMenu()

        let speech = NSMenu()
        let automatic = item("Detect Automatically", #selector(AppDelegate.selectSourceLanguage(_:)))
        automatic.representedObject = ""
        automatic.state = settings.sourceLanguageCode.isEmpty ? .on : .off
        speech.addItem(automatic)
        speech.addItem(.separator())
        addLanguages(to: speech, current: settings.sourceLanguageCode, action: #selector(AppDelegate.selectSourceLanguage(_:)))
        menu.addItem(submenu("Speech Language", speech))

        let targets = NSMenu()
        addLanguages(to: targets, current: settings.targetLanguageCode, action: #selector(AppDelegate.selectTargetLanguage(_:)))
        menu.addItem(submenu("Translate Into", targets))

        let second = NSMenu()
        let none = item("None", #selector(AppDelegate.selectSecondTargetLanguage(_:)))
        none.representedObject = ""
        none.state = settings.secondTargetLanguage == nil ? .on : .off
        second.addItem(none)
        second.addItem(.separator())
        addLanguages(to: second, current: settings.secondTargetLanguage?.code ?? "", action: #selector(AppDelegate.selectSecondTargetLanguage(_:)))
        menu.addItem(submenu("Also Translate Into", second))
        return menu
    }

    /// The favourites (plus the current choice), then a way into Settings for the rest.
    private func addLanguages(to menu: NSMenu, current: String, action: Selector) {
        var codes = favouriteLanguages
        if !current.isEmpty, !codes.contains(current) {
            codes.insert(current, at: 0)
        }
        for code in codes {
            guard let language = Languages.language(code: code) else { continue }
            let entry = item(language.menuTitle, action)
            entry.representedObject = language.code
            entry.state = current == language.code ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("More Languages…", #selector(AppDelegate.showSettings(_:))))
    }

    private func displayStyleMenu() -> NSMenu {
        let menu = NSMenu()
        for style in DisplayStyle.allCases {
            let entry = item(style.title, #selector(AppDelegate.selectDisplayStyle(_:)))
            entry.representedObject = style.rawValue
            entry.state = settings.displayStyle == style ? .on : .off
            entry.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        let themes = NSMenu()
        for theme in ThemeID.allCases {
            let entry = item(theme.title, #selector(AppDelegate.selectTheme(_:)))
            entry.representedObject = theme.rawValue
            entry.state = settings.themeID == theme ? .on : .off
            themes.addItem(entry)
        }
        menu.addItem(submenu("Theme", themes))

        // With two languages pinned, they are the two columns.
        if settings.secondTargetLanguage == nil {
            let original = item("Show Original Side by Side", #selector(AppDelegate.toggleShowOriginal(_:)))
            original.state = settings.showOriginal ? .on : .off
            menu.addItem(original)
        }
        if settings.displayStyle == .teleprompter {
            let mirror = item("Mirror Teleprompter", #selector(AppDelegate.toggleMirror(_:)))
            mirror.state = settings.teleprompterMirror ? .on : .off
            menu.addItem(mirror)
        }
        if settings.displayStyle == .ticker {
            let uppercase = item("Uppercase Ticker", #selector(AppDelegate.toggleTickerUppercase(_:)))
            uppercase.state = settings.tickerUppercase ? .on : .off
            menu.addItem(uppercase)
        }
        return menu
    }

    private func exportMenu() -> NSMenu {
        let menu = NSMenu()
        for format in TranscriptExporter.Format.allCases {
            let entry = item(format.title + "…", #selector(AppDelegate.exportTranscript(_:)))
            entry.representedObject = format.rawValue
            menu.addItem(entry)
        }
        return menu
    }

    // MARK: Helpers

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = delegate
        return entry
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }

    /// Shows a global shortcut beside the item, unless it couldn't be registered.
    private func shortcut(_ shortcut: GlobalShortcut, on entry: NSMenuItem) -> NSMenuItem {
        if hotKeys.registered.contains(shortcut) {
            shortcut.apply(to: entry)
        }
        return entry
    }
}

/// The menu-bar icon: Earshot's only way in, so it is always shown.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let builder: QuickMenuBuilder
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, builder: QuickMenuBuilder) {
        self.builder = builder
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        model.$isListening
            .combineLatest(model.$isSpeaking, model.$banner)
            .receive(on: RunLoop.main)
            .sink { [weak self] listening, speaking, banner in
                self?.updateIcon(listening: listening, speaking: speaking, banner: banner)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(listening: Bool, speaking: Bool, banner: Banner?) {
        let name: String
        let tip: String
        if let banner, banner.kind != .info {
            name = "exclamationmark.triangle"
            tip = "Earshot — \(banner.message)"
        } else if listening {
            name = speaking ? "waveform.circle.fill" : "waveform.circle"
            tip = "Earshot — listening"
        } else {
            name = "captions.bubble"
            tip = "Earshot — paused"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Earshot")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        builder.populate(menu)
    }
}

/// Never shown (Earshot has no menu bar of its own), but its key equivalents keep
/// ⌘C, ⌘V, ⌘W and friends working in the Settings window's text fields.
enum MainMenu {
    @MainActor
    static func build(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = delegate
        app.addItem(settings)
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Earshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "Earshot", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        return main
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        main.addItem(item)
    }
}
