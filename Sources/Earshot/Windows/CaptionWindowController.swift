import AppKit
import Combine
import SwiftUI

/// A borderless panel that never activates Earshot, so typing and clicking stay
/// with whatever app is in front. It can only take the keyboard while the
/// captions are being moved (for Esc and Return).
final class CaptionPanel: NSPanel {
    static let minimumSize = NSSize(width: 420, height: 130)

    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// State the caption views share with their window.
@MainActor
final class CaptionChrome: ObservableObject {
    /// True while the captions are unlocked for moving and resizing.
    @Published var isAdjusting = false
}

/// Shows the captions above every app and full-screen Space. The window ignores
/// the mouse, so whatever is underneath (a slideshow, say) keeps working,
/// except while Move & Resize has unlocked it.
@MainActor
final class CaptionWindowController: NSWindowController {
    /// The old panel's name, so the captions open where the panel used to be.
    private static let frameName = "EarshotPanel"
    /// Unlocked captions lock themselves again after this long without mouse activity.
    private static let autoLockNanoseconds: UInt64 = 30_000_000_000

    private let model: AppModel
    private let settings: AppSettings
    let chrome = CaptionChrome()
    private let overlay = CaptionAdjustOverlay()
    private var keyMonitor: Any?
    private var autoLock: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        let panel = CaptionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 230),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Earshot Captions"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !settings.theme.bare
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Above full-screen apps and ordinary floating windows. Menus still draw above the captions; alerts and save panels draw below them, but the captions never block their clicks.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.minSize = CaptionPanel.minimumSize
        super.init(window: panel)

        let container = NSView()
        panel.contentView = container
        let hostingView = NSHostingView(rootView: CaptionRootView(model: model, settings: settings, chrome: chrome))
        hostingView.sizingOptions = []
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        overlay.onActivity = { [weak self] in self?.restartAutoLock() }
        overlay.onDone = { [weak self] in self?.endAdjusting() }
        container.addSubview(overlay)

        if !panel.setFrameUsingName(Self.frameName) {
            placeAtBottomOfMainScreen()
        }
        panel.setFrameAutosaveName(Self.frameName)
        keepOnScreen()

        // A projector can be unplugged mid-session; bring the captions back to a screen that's still there.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.keepOnScreen() }
            .store(in: &cancellables)

        // Transparent windows compute their shadow from what's drawn, and the captions change
        // shape (nothing, the Listening pill, text, a notice, the Move & Resize outline), so
        // recompute it once they settle, after the 0.25 s transitions finish.
        // Not on every level-meter tick: `model.level` is deliberately left out.
        Publishers.MergeMany(
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            model.$revision.map { _ in () }.eraseToAnyPublisher(),
            model.$isListening.map { _ in () }.eraseToAnyPublisher(),
            model.$isSpeaking.map { _ in () }.eraseToAnyPublisher(),
            model.$banner.map { _ in () }.eraseToAnyPublisher(),
            chrome.$isAdjusting.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] in self?.refreshShadow() }
        .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Showing

    func show() {
        // Earshot is never the active app, so a plain orderFront would be ignored.
        window?.orderFrontRegardless()
        model.captionsVisible = true
    }

    func hide() {
        endAdjusting()
        window?.orderOut(nil)
        model.captionsVisible = false
    }

    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    // MARK: Move & Resize

    /// Unlocks the captions: outline, Done button and grip appear, and the mouse works on them.
    func beginAdjusting() {
        guard let panel = window as? CaptionPanel, !chrome.isAdjusting else { return }
        show()
        chrome.isAdjusting = true
        overlay.accentColor = NSColor(settings.theme.accent)
        overlay.gripColor = NSColor(settings.theme.text)
        overlay.isHidden = false
        panel.ignoresMouseEvents = false
        panel.allowsKey = true
        // A non-activating panel becomes key without bringing Earshot forward.
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only Esc aimed at the captions; Esc in the Settings window is Settings' business.
            guard let self, event.keyCode == 53, event.window === self.window else { return event }  // 53 = Esc
            self.endAdjusting()
            return nil
        }
        restartAutoLock()
    }

    /// Locks the captions again so clicks pass through.
    func endAdjusting() {
        guard let panel = window as? CaptionPanel, chrome.isAdjusting else { return }
        chrome.isAdjusting = false
        overlay.isHidden = true
        panel.ignoresMouseEvents = true
        panel.allowsKey = false
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        autoLock?.cancel()
        autoLock = nil
        // Hand the keyboard back to the app in front: ordering out is what makes a panel give up key.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private func restartAutoLock() {
        autoLock?.cancel()
        autoLock = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoLockNanoseconds)
            guard !Task.isCancelled else { return }
            self?.endAdjusting()
        }
    }

    // MARK: Placement

    /// The Shadow theme draws its own shadow under the text, so the window adds none;
    /// otherwise macOS recomputes the window's shadow from what's drawn.
    private func refreshShadow() {
        guard let window else { return }
        window.hasShadow = !settings.theme.bare
        window.invalidateShadow()
    }

    private func keepOnScreen() {
        guard let window else { return }
        if !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            placeAtBottomOfMainScreen()
        }
    }

    private func placeAtBottomOfMainScreen() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 72))
    }
}
