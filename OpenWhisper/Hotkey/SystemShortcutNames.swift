import AppKit
import Carbon.HIToolbox

/// Maps well-known macOS symbolic hotkey IDs to human-readable names.
/// These IDs come from `com.apple.symbolichotkeys` in UserDefaults.
enum SystemShortcutNames {
    // Known symbolic hotkey IDs → display names
    private static let knownHotkeys: [Int: String] = [
        7: "Move focus to the menu bar",
        8: "Move focus to the Dock",
        9: "Move focus to the active window",
        10: "Move focus to the window toolbar",
        12: "Move focus to the floating window",
        13: "Change the way Tab moves focus",
        15: "Turn zoom on or off",
        17: "Zoom in",
        19: "Zoom out",
        21: "Invert colors",
        23: "Turn image smoothing on or off",
        25: "Increase contrast",
        26: "Decrease contrast",
        27: "Move focus to next window",
        28: "Save picture of screen as a file",
        29: "Copy picture of screen to the clipboard",
        30: "Save picture of selected area as a file",
        31: "Copy picture of selected area to the clipboard",
        32: "Mission Control",
        33: "Application windows",
        34: "Show Desktop",
        35: "Move left a space",
        36: "Move right a space",
        37: "Show Spotlight search",
        51: "Toggle Dock hiding",
        52: "Show Accessibility controls",
        57: "Move focus to the status menus",
        59: "Turn VoiceOver on or off",
        60: "Select the previous input source",
        61: "Select next source in Input menu",
        64: "Show Spotlight search",
        65: "Show Finder search window",
        70: "Dashboard",
        73: "Front Row",
        79: "Move left a space",
        80: "Move right a space",
        81: "Move up a space",
        118: "Switch to Desktop 1",
        119: "Switch to Desktop 2",
        120: "Switch to Desktop 3",
        121: "Switch to Desktop 4",
        160: "Show Launchpad",
        162: "Show Notification Center",
        163: "Turn Do Not Disturb on or off",
        175: "Show Quick Note",
    ]

    /// Checks if a key+modifiers combination matches any enabled system symbolic hotkey.
    /// Returns the name of the conflicting hotkey, or nil if no conflict.
    static func conflictingSystemHotkeyName(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let prefs = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let hotkeys = prefs["AppleSymbolicHotKeys"] as? [String: Any] else {
            return nil
        }

        let carbonModifiers = carbonModifierFlags(from: modifiers)

        for (idString, value) in hotkeys {
            guard let id = Int(idString),
                  let dict = value as? [String: Any],
                  let enabled = dict["enabled"] as? Bool, enabled,
                  let params = dict["value"] as? [String: Any],
                  let parameters = params["parameters"] as? [Int],
                  parameters.count >= 3 else {
                continue
            }

            let hotkeyKeyCode = parameters[1]
            let hotkeyModifiers = parameters[2]

            if hotkeyKeyCode == keyCode && hotkeyModifiers == carbonModifiers {
                return knownHotkeys[id] ?? "System shortcut (ID \(id))"
            }
        }

        return nil
    }

    /// Converts NSEvent modifier flags to the Carbon modifier format used by symbolic hotkeys.
    private static func carbonModifierFlags(from flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        return carbon
    }
}
