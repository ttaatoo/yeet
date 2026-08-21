//
//  GlobalHotKeyManager.swift
//  kero
//

import AppKit
import Carbon

/// Manages a process-wide summon/hide shortcut via Carbon Event Manager.
///
/// `RegisterEventHotKey` works without Accessibility permission. The combo is
/// a system resource, not per-bundle: Debug `sh.kerox.dev` and Release
/// `sh.kerox` cannot both own the same keys, so callers must surface a failed
/// register instead of treating the Settings row as bound.
@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    /// `true` after a successful register, or when the hotkey is cleared.
    /// `false` when Carbon rejected the combo (already taken, invalid, …).
    private(set) var lastRegistrationSucceeded = true

    private init() {
        installEventHandler()
    }

    /// Registers `keyCombo`, replacing any previous binding.
    ///
    /// `nil` unregisters and counts as success. On failure the previous
    /// binding is already gone and `handler` is not kept — Settings must show
    /// that the displayed combo is not live.
    @discardableResult
    func register(keyCombo: KeyCombo?, handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = nil

        guard let keyCombo else {
            lastRegistrationSucceeded = true
            return true
        }

        guard keyCombo.isValid else {
            lastRegistrationSucceeded = false
            NSLog("kero: refusing invalid global hotkey (need Command, Control, or Option)")
            return false
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType("kero".fourCharCodeValue)
        hotKeyID.id = 1

        var tempRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCombo.keyCode),
            UInt32(keyCombo.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &tempRef
        )

        // RegisterEventHotKey does not promise a valid out-ref on failure.
        if status == noErr, let tempRef {
            hotKeyRef = tempRef
            self.handler = handler
            lastRegistrationSucceeded = true
            return true
        }

        NSLog("kero: failed to register global hotkey: OSStatus \(status)")
        lastRegistrationSucceeded = false
        return false
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    fileprivate func handleHotKeyPressed() {
        handler?()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Typed as EventHandlerUPP so Swift emits a C function pointer.
        // The body only reads `userData` (no captures).
        let callback: EventHandlerUPP = { _, _, userData in
            carbonHotKeyPressed(userData)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
    }
}

/// Carbon's handler is a C function pointer, so it cannot be a MainActor
/// closure. The dispatcher target is the main event loop.
private nonisolated func carbonHotKeyPressed(
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<GlobalHotKeyManager>
        .fromOpaque(userData)
        .takeUnretainedValue()
    assumeMainActor {
        manager.handleHotKeyPressed()
    }
    return noErr
}

/// A keyboard shortcut: hardware key code plus Carbon modifier flags.
struct KeyCombo: Equatable, Hashable {
    let keyCode: Int
    /// Carbon modifier mask (`cmdKey` / `optionKey` / `controlKey` / `shiftKey`).
    let modifiers: Int

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Valid hotkey from a key-down: Command, Control, or Option required.
    /// Shift may accompany those but is not enough on its own (Shift+A is
    /// typing "A"). Bare modifier keys are rejected.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }

        let modifierFlags = event.modifierFlags
        guard !modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }

        let bareModifierCodes: Set<UInt16> = [
            54, 55, // Right / left Command
            56, 60, // Left / right Shift
            57,     // Caps Lock
            58, 61, // Left / right Option
            59, 62, // Left / right Control
            63,     // Function
        ]
        guard !bareModifierCodes.contains(event.keyCode) else { return nil }

        self.keyCode = Int(event.keyCode)
        self.modifiers = Self.carbonModifiers(from: modifierFlags)
    }

    /// Command, Control, or Option must be present. Used for hand-edited TOML.
    var isValid: Bool {
        let command = Int(cmdKey)
        let control = Int(controlKey)
        let option = Int(optionKey)
        return (modifiers & command) != 0
            || (modifiers & control) != 0
            || (modifiers & option) != 0
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.command) { carbon |= Int(cmdKey) }
        if flags.contains(.control) { carbon |= Int(controlKey) }
        if flags.contains(.option) { carbon |= Int(optionKey) }
        if flags.contains(.shift) { carbon |= Int(shiftKey) }
        return carbon
    }

    /// User-facing binding, e.g. `⌥Space` or `⌘⇧K`.
    var displayString: String {
        var parts: [String] = []
        if (modifiers & Int(controlKey)) != 0 { parts.append("⌃") }
        if (modifiers & Int(optionKey)) != 0 { parts.append("⌥") }
        if (modifiers & Int(shiftKey)) != 0 { parts.append("⇧") }
        if (modifiers & Int(cmdKey)) != 0 { parts.append("⌘") }

        let keyString: String
        switch keyCode {
        case 49: keyString = "Space"
        case 36: keyString = "↩"
        case 48: keyString = "⇥"
        case 51: keyString = "⌫"
        case 53: keyString = "⎋"
        case 123: keyString = "←"
        case 124: keyString = "→"
        case 125: keyString = "↓"
        case 126: keyString = "↑"
        case 116: keyString = "Page Up"
        case 121: keyString = "Page Down"
        case 115: keyString = "Home"
        case 119: keyString = "End"
        case 122: keyString = "F1"
        case 120: keyString = "F2"
        case 99: keyString = "F3"
        case 118: keyString = "F4"
        case 96: keyString = "F5"
        case 97: keyString = "F6"
        case 98: keyString = "F7"
        case 100: keyString = "F8"
        case 101: keyString = "F9"
        case 109: keyString = "F10"
        case 103: keyString = "F11"
        case 111: keyString = "F12"
        default:
            if let chars = Self.characterForKeyCode(keyCode) {
                keyString = chars.uppercased()
            } else {
                keyString = "?"
            }
        }

        parts.append(keyString)
        return parts.joined()
    }

    private static func characterForKeyCode(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let layoutData = TISGetInputSourceProperty(
            source,
            kTISPropertyUnicodeKeyLayoutData
        ) else {
            return nil
        }

        let layout = unsafeBitCast(layoutData, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layout),
            to: UnsafePointer<UCKeyboardLayout>.self
        )

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            4,
            &length,
            &chars
        )

        return length > 0 ? String(utf16CodeUnits: chars, count: length) : nil
    }

    /// Option+Space — iTerm2/Warp-style summon. Also Raycast's default; the
    /// Settings row mentions that, and a failed register is visible there.
    static let `default` = KeyCombo(
        keyCode: 49,
        modifiers: Int(optionKey)
    )
}

private extension String {
    var fourCharCodeValue: UInt32 {
        var result: UInt32 = 0
        for char in utf8.prefix(4) {
            result = result << 8 + UInt32(char)
        }
        return result
    }
}
