import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox

/// A custom shortcut recorder that allows capturing Escape and other keys
/// that the built-in KeyboardShortcuts.Recorder intercepts.
struct ShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    @State private var isRecording = false
    @State private var currentShortcut: KeyboardShortcuts.Shortcut?
    @State private var eventMonitor: Any?
    @State private var wasShortcutEnabledBeforeRecording = false
    @State private var conflictMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    Text(displayText)
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)

                if currentShortcut != nil, !isRecording {
                    Button {
                        KeyboardShortcuts.setShortcut(nil, for: name)
                        currentShortcut = nil
                        conflictMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let conflictMessage {
                Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            currentShortcut = KeyboardShortcuts.getShortcut(for: name) ?? name.defaultShortcut
            if let shortcut = currentShortcut {
                checkForConflicts(shortcut)
            }
        }
        .onDisappear {
            if isRecording {
                stopRecording()
            }
        }
    }

    private var displayText: String {
        if isRecording {
            return "Press a key..."
        }
        if let shortcut = currentShortcut {
            return shortcutDisplayString(shortcut)
        }
        return "Record Shortcut"
    }

    private func startRecording() {
        isRecording = true
        conflictMessage = nil
        wasShortcutEnabledBeforeRecording = KeyboardShortcuts.isEnabled(for: name)
        // Temporarily disable the shortcut so it doesn't fire while we record a new one
        KeyboardShortcuts.disable(name)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = KeyboardShortcuts.Key(rawValue: Int(event.keyCode))
            let shortcut = KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            currentShortcut = shortcut
            checkForConflicts(shortcut)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        // Always re-enable the shortcut if one is now set.
        // The old logic would disable shortcuts that had no previous binding
        // (wasShortcutEnabledBeforeRecording=false), which broke newly assigned shortcuts.
        if KeyboardShortcuts.getShortcut(for: name) != nil {
            KeyboardShortcuts.enable(name)
        }
    }

    private func checkForConflicts(_ shortcut: KeyboardShortcuts.Shortcut) {
        // Check system shortcuts
        if let key = shortcut.key {
            if let systemName = SystemShortcutNames.conflictingSystemHotkeyName(
                keyCode: key.rawValue,
                modifiers: shortcut.modifiers
            ) {
                conflictMessage = "Conflicts with: \(systemName)"
                return
            }
        }

        // Check if taken by the app's main menu
        if shortcut.isTakenByMainMenu {
            conflictMessage = "Conflicts with a menu item shortcut"
            return
        }

        conflictMessage = nil
    }

    private func shortcutDisplayString(_ shortcut: KeyboardShortcuts.Shortcut) -> String {
        shortcut.displayString
    }
}

extension KeyboardShortcuts.Shortcut {
    var displayString: String {
        var parts: [String] = []
        let mods = modifiers
        if mods.contains(.control) { parts.append("\u{2303}") }
        if mods.contains(.option) { parts.append("\u{2325}") }
        if mods.contains(.shift) { parts.append("\u{21E7}") }
        if mods.contains(.command) { parts.append("\u{2318}") }

        if let key = key {
            parts.append(key.displayString)
        }

        return parts.joined()
    }

    /// Whether this shortcut conflicts with the app's main menu shortcuts.
    var isTakenByMainMenu: Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }
        return menuContainsShortcut(mainMenu)
    }

    private func menuContainsShortcut(_ menu: NSMenu) -> Bool {
        for item in menu.items {
            let equiv = item.keyEquivalent
            if !equiv.isEmpty {
                let itemMods = item.keyEquivalentModifierMask
                if let key = key,
                   equiv.lowercased() == keyCharacter(for: key)?.lowercased(),
                   itemMods == modifiers {
                    return true
                }
            }
            if let submenu = item.submenu, menuContainsShortcut(submenu) {
                return true
            }
        }
        return false
    }

    private func keyCharacter(for key: KeyboardShortcuts.Key) -> String? {
        let keyCode = UInt16(key.rawValue)
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
        let keyLayoutPtr = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0
        let status = UCKeyTranslate(
            keyLayoutPtr,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        if status == noErr, length > 0 {
            return String(utf16CodeUnits: chars, count: length)
        }
        return nil
    }
}

extension KeyboardShortcuts.Key {
    var displayString: String {
        switch self {
        case .escape: return "Esc"
        case .return: return "\u{21A9}"
        case .tab: return "\u{21E5}"
        case .space: return "\u{2423}"
        case .delete: return "\u{232B}"
        case .deleteForward: return "\u{2326}"
        case .upArrow: return "\u{2191}"
        case .downArrow: return "\u{2193}"
        case .leftArrow: return "\u{2190}"
        case .rightArrow: return "\u{2192}"
        case .home: return "\u{2196}"
        case .end: return "\u{2198}"
        case .pageUp: return "\u{21DE}"
        case .pageDown: return "\u{21DF}"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        case .keypad0: return "Num 0"
        case .keypad1: return "Num 1"
        case .keypad2: return "Num 2"
        case .keypad3: return "Num 3"
        case .keypad4: return "Num 4"
        case .keypad5: return "Num 5"
        case .keypad6: return "Num 6"
        case .keypad7: return "Num 7"
        case .keypad8: return "Num 8"
        case .keypad9: return "Num 9"
        case .keypadDecimal: return "Num ."
        case .keypadMultiply: return "Num *"
        case .keypadPlus: return "Num +"
        case .keypadClear: return "Num Clear"
        case .keypadDivide: return "Num /"
        case .keypadEnter: return "Num \u{21A9}"
        case .keypadMinus: return "Num -"
        case .keypadEquals: return "Num ="
        default:
            let keyCode = UInt16(rawValue)
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
            let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            guard let layoutDataRef else {
                return "Key(\(rawValue))"
            }
            let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
            let keyLayoutPtr = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            let status = UCKeyTranslate(
                keyLayoutPtr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            if status == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
            return "Key(\(rawValue))"
        }
    }
}
