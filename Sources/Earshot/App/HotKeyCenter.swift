import AppKit
import Carbon.HIToolbox

/// Registers the `GlobalShortcut`s with Carbon's hot-key API, which delivers them
/// while another app is in front and needs no Accessibility permission.
@MainActor
final class HotKeyCenter: ObservableObject {
    /// Shortcuts that registered. A clash with another app or a system shortcut isn't always reported, so a listed shortcut can still be shadowed.
    @Published private(set) var registered = Set<GlobalShortcut>()

    private let perform: (GlobalShortcut) -> Void
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    /// 'ERSH'
    private static let signature: OSType = 0x4552_5348

    init(perform: @escaping (GlobalShortcut) -> Void) {
        self.perform = perform
    }

    func registerAll() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, let shortcut = GlobalShortcut(rawValue: hotKeyID.id) else { return status }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot keys on the main thread.
                MainActor.assumeIsolated { center.perform(shortcut) }
                return noErr
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        for shortcut in GlobalShortcut.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: shortcut.rawValue)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                GlobalShortcut.carbonModifiers,
                id,
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyNoOptions),
                &ref
            )
            if status == noErr, let ref {
                hotKeys.append(ref)
                registered.insert(shortcut)
            }
        }
    }
}
