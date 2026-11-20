import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

public enum KeySender {
    public static let myWhooshBundleID = "com.whoosh.whooshgame"
    public static let myWhooshAppURL = URL(fileURLWithPath: "/Applications/MyWhoosh Indoor Cycling App.app")

    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    public static func isMyWhooshRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: myWhooshBundleID).isEmpty
    }

    public static func launchMyWhoosh() {
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: myWhooshBundleID).first {
            existing.activate(options: [.activateIgnoringOtherApps])
            return
        }
        guard FileManager.default.fileExists(atPath: myWhooshAppURL.path) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: myWhooshAppURL, configuration: config)
    }

    public static func focusMyWhooshIfRunning() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: myWhooshBundleID).first else {
            return
        }
        if !app.isActive {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    public static func send(key: KeyCode, down: Bool, autoFocusMyWhoosh: Bool) {
        if down && autoFocusMyWhoosh {
            focusMyWhooshIfRunning()
        }
        let vk = virtualKeyCode(for: key)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else {
            return
        }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private static func virtualKeyCode(for key: KeyCode) -> CGKeyCode {
        switch key {
        case .i:     return CGKeyCode(kVK_ANSI_I)
        case .k:     return CGKeyCode(kVK_ANSI_K)
        case .u:     return CGKeyCode(kVK_ANSI_U)
        case .enter: return CGKeyCode(kVK_Return)
        case .left:  return CGKeyCode(kVK_LeftArrow)
        case .right: return CGKeyCode(kVK_RightArrow)
        case .up:    return CGKeyCode(kVK_UpArrow)
        case .down:  return CGKeyCode(kVK_DownArrow)
        case .space: return CGKeyCode(kVK_Space)
        case .esc:   return CGKeyCode(kVK_Escape)
        }
    }
}
