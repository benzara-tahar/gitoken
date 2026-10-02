import AppKit
import Carbon.HIToolbox
import GitokenCore
import os

/// System-wide shortcut through Carbon `RegisterEventHotKey`, which needs no Accessibility permission (unlike a
/// global `NSEvent` key monitor). Follows `settings.hotKey` and stands down while Settings records a new one.
@MainActor
final class GlobalHotKey {
    static let log = Logger(subsystem: "io.github.benzara-tahar.Gitoken", category: "HotKey")
    private static let signature: OSType = 0x4754_4B4E  // "GTKN"

    private let model: NotchModel
    private let action: @MainActor () -> Void
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var registered: HotKey?

    init(model: NotchModel, action: @escaping @MainActor () -> Void) {
        self.model = model
        self.action = action
        installHandler()
        sync()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard read == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
                let target = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { target.action() }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { Self.log.error("InstallEventHandler failed: \(status)") }
    }

    /// Re-registers whenever the setting or the recorder state changes.
    private func sync() {
        let wanted = withObservationTracking {
            model.isRecordingHotKey ? nil : model.settings.hotKey
        } onChange: { [weak self] in
            Task { @MainActor in self?.sync() }
        }
        guard wanted != registered else { return }
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
        registered = nil
        model.hotKeyUnavailable = false
        guard let wanted else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(wanted.keyCode), wanted.carbonModifiers, EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(), 0, &ref)
        if status == noErr {
            registration = ref
            registered = wanted
        } else {
            // Typically eventHotKeyExistsErr: another app owns the combination.
            Self.log.error("RegisterEventHotKey \(wanted.displayString, privacy: .public) failed: \(status)")
            model.hotKeyUnavailable = true
        }
    }
}

extension HotKey {
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// From a key press in the recorder; nil without ⌘, ⌥, or ⌃ (a bare or shift-only key would hijack typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        guard !modifiers.isEmpty else { return nil }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }

    /// "⌥⌘G", in the system's modifier order.
    var displayString: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The character the key types on the current keyboard layout (so ⌥⌘G shows "G" on QWERTY and AZERTY alike).
    private static func keyName(_ keyCode: UInt16) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
