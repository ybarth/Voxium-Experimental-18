import AVFoundation
import AppKit

enum Permissions {
    static var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    static func promptAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static var allGranted: Bool {
        isMicrophoneAuthorized && isAccessibilityGranted
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - App location helpers

    /// The resolved path to the running .app bundle.
    static var appBundlePath: String {
        Bundle.main.bundleURL.path
    }

    /// Reveal the running .app bundle in Finder so the user can identify it
    /// in System Settings > Privacy > Accessibility.
    static func revealAppInFinder() {
        NSWorkspace.shared.selectFile(
            Bundle.main.bundleURL.path,
            inFileViewerRootedAtPath: Bundle.main.bundleURL.deletingLastPathComponent().path
        )
    }

    // MARK: - Accessibility permission reset

    /// Reset the accessibility TCC entry for this bundle ID.
    /// After calling this the app will need to be re-granted Accessibility permission.
    /// Returns true if the tccutil command exited successfully.
    @discardableResult
    static func resetAccessibilityPermission() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Reset *and* immediately re-prompt for Accessibility access.
    /// Useful after rebuilds where the old permission entry is stale.
    static func resetAndRePromptAccessibility() {
        resetAccessibilityPermission()
        // Small delay so the TCC database settles before we re-prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            promptAccessibilityIfNeeded()
        }
    }
}
