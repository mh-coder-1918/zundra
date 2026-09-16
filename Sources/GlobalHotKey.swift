import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey backed by Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are the one way to get a global shortcut *without* asking the
/// user for Accessibility permission (which `NSEvent` global monitors require).
/// `register()` / `unregister()` are idempotent, so it's safe to toggle.
final class GlobalHotKey {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let onPress: @MainActor () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_ANSI_T`.
    ///   - modifiers: Carbon modifier mask, e.g. `controlKey | optionKey | cmdKey`.
    init(keyCode: UInt32, modifiers: UInt32, onPress: @escaping @MainActor () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.onPress = onPress
    }

    var isRegistered: Bool { hotKeyRef != nil }

    func register() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // The callback must be a bare C function pointer (no captures); it recovers
        // `self` from the userData pointer and hops to the main actor to fire.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                let action = hotKey.onPress
                DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D425458), id: 1) // 'MBTX'
        RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit { unregister() }
}
