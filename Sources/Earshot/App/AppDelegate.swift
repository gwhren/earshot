import AppKit
import EarshotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let settings = AppSettings()
    private(set) lazy var model = AppModel(settings: settings)

    private var captions: CaptionWindowController!
    private var statusItem: StatusItemController!
    private var quickMenu: QuickMenuBuilder!
    private var hotKeys: HotKeyCenter!
    private var settingsWindow: SettingsWindowController?
    /// The app that was in front before Settings or the export panel took the keyboard, so it
    /// can have it back (a full-screen slideshow whose clicker and arrow keys must keep working).
    private var appBeforeActivating: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app: no Dock icon, and every control lives in the status item's menu.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.build(delegate: self)

        captions = CaptionWindowController(model: model, settings: settings)
        hotKeys = HotKeyCenter { [weak self] shortcut in self?.perform(shortcut) }
        hotKeys.registerAll()
        quickMenu = QuickMenuBuilder(delegate: self, model: model, settings: settings, hotKeys: hotKeys)
        statusItem = StatusItemController(model: model, builder: quickMenu)

        captions.show()
        Task {
            await model.refreshServer()
            if settings.listenAtLaunch {
                model.startListening()
            }
        }
    }

    // Stay resident: closing a window never quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Opening Earshot again (from Finder or Spotlight) brings the captions back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        captions.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopListening()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Actions

    @objc func toggleListening(_ sender: Any?) {
        model.toggleListening()
    }

    @objc func toggleCaptions(_ sender: Any?) {
        captions.toggle()
    }

    @objc func adjustCaptions(_ sender: Any?) {
        captions.beginAdjusting()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = SettingsWindowController(model: model, settings: settings, hotKeys: hotKeys)
            controller.onClose = { [weak self] in self?.returnFocus() }
            settingsWindow = controller
        }
        activateForInput()
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func selectDisplayStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = DisplayStyle(rawValue: raw) else { return }
        settings.displayStyle = style
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = ThemeID(rawValue: raw) else { return }
        settings.themeID = theme
    }

    @objc func selectSourceLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        settings.sourceLanguageCode = code
    }

    @objc func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        settings.targetLanguageCode = code
    }

    @objc func selectSecondTargetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        settings.secondTargetLanguageCode = code
    }

    @objc func toggleShowOriginal(_ sender: Any?) {
        settings.showOriginal.toggle()
    }

    @objc func toggleMirror(_ sender: Any?) {
        settings.teleprompterMirror.toggle()
    }

    @objc func toggleTickerUppercase(_ sender: Any?) {
        settings.tickerUppercase.toggle()
    }

    @objc func increaseTextSize(_ sender: Any?) {
        settings.adjustFontSize(by: 2)
    }

    @objc func decreaseTextSize(_ sender: Any?) {
        settings.adjustFontSize(by: -2)
    }

    @objc func clearTranscript(_ sender: Any?) {
        model.clearTranscript()
    }

    @objc func copyTranscript(_ sender: Any?) {
        model.copyTranscript()
    }

    @objc func exportTranscript(_ sender: NSMenuItem) {
        let format = (sender.representedObject as? String).flatMap(TranscriptExporter.Format.init(rawValue:)) ?? .plainText
        // A menu-bar app isn't active when its menu is used; the save panel needs it to be.
        activateForInput()
        model.exportTranscript(as: format) { [weak self] in self?.returnFocus() }
    }

    @objc func performBannerAction(_ sender: Any?) {
        guard let action = model.banner?.action else { return }
        model.perform(action)
    }

    @objc func dismissBanner(_ sender: Any?) {
        model.dismissBanner()
    }

    /// Makes Earshot the active app so a window can take the keyboard, remembering what was in front.
    private func activateForInput() {
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            appBeforeActivating = front
        }
        NSApp.activate()
    }

    /// Hands activation back once Settings or the export panel is done, but only if Earshot is
    /// still the active app, so it never pulls focus away from an app the user switched to.
    private func returnFocus() {
        defer { appBeforeActivating = nil }
        guard NSApp.isActive else { return }
        appBeforeActivating?.activate()
    }

    private func perform(_ shortcut: GlobalShortcut) {
        switch shortcut {
        case .toggleListening: model.toggleListening()
        case .toggleCaptions: captions.toggle()
        case .biggerText: settings.adjustFontSize(by: 2)
        case .smallerText: settings.adjustFontSize(by: -2)
        }
    }

    // MARK: - Menu state

    // Check marks are set when the menu is built; this only greys out what can't be done.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(clearTranscript(_:)), #selector(copyTranscript(_:)), #selector(exportTranscript(_:)):
            return model.hasTranscript
        default:
            return true
        }
    }
}
