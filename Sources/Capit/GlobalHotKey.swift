import Carbon
import Foundation

/// Thin wrapper around the Carbon global-hotkey API.
/// `RegisterEventHotKey` is the standard macOS mechanism for app-global shortcuts
/// and — unlike `NSEvent` global monitors — does **not** require Accessibility trust.
final class GlobalHotKeyManager {

    /// 4-byte signature for our hot key IDs.
    private static let signature = OSType("CPTP")

    var onPress: ((UInt32) -> Void)?

    private var installed = false
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]

    /// Registers a system-wide hot key. Key codes are Carbon virtual key codes.
    /// - Parameters:
    ///   - id: arbitrary ID reported back through `onPress`.
    ///   - keyCode: Carbon virtual key code (e.g. 20 == "3", 21 == "4").
    ///   - modifiers: Carbon modifier mask (cmdKey | shiftKey | ...).
    /// - Returns: true if registration succeeded (OSStatus noErr).
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> Bool {
        installIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotKeyRef)
        guard status == noErr, let hotKeyRef else {
            NSLog("[Capit] RegisterEventHotKey failed (status \(status)) for id \(id)")
            return false
        }
        hotKeyRefs[id] = hotKeyRef
        return true
    }

    func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // Non-capturing C callback: manager is recovered from the refcon userData.
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            let manager = Unmanaged<GlobalHotKeyManager>
                .fromOpaque(userData)
                .takeUnretainedValue()
            manager.onPress?(hotKeyID.id)
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(),
                            handler,
                            1,
                            &eventType,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandlerRef)
    }
}

extension OSType {
    /// Builds a four-character-code OSType from a Swift string literal.
    init(_ string: String) {
        var value: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        self = value
    }
}
