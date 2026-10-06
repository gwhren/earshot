import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    /// Called each time the window closes; the window is reused, so this fires on every close.
    var onClose: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, settings: AppSettings, hotKeys: HotKeyCenter) {
        let root = SettingsView()
            .environmentObject(model)
            .environmentObject(settings)
            .environmentObject(hotKeys)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Earshot Settings"
        // Not miniaturizable: with no Dock icon there'd be nowhere obvious to get it back from.
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // Open on whatever Space is active, including a full-screen presentation's.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setContentSize(NSSize(width: 640, height: 600))
        window.center()
        window.setFrameAutosaveName("EarshotSettings")
        super.init(window: window)

        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.onClose?() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
