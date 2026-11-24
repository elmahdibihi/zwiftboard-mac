import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
public enum KeySender {
    nonisolated public static let myWhooshBundleID = "com.whoosh.whooshgame"
    nonisolated public static let myWhooshAppURL = URL(fileURLWithPath: "/Applications/MyWhoosh Indoor Cycling App.app")

    /// Minimum hold duration (30ms ≈ ~2 frames at 60fps) so buffered BLE press+release
    /// bursts are never missed by Unreal Engine's per-frame input polling.
    private static let minTapHoldSeconds: TimeInterval = 0.030
    private static var keyDownAt: [KeyCode: Date] = [:]
    private static var pendingUpWork: [KeyCode: DispatchWorkItem] = [:]

    nonisolated public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    nonisolated public static func isMyWhooshRunning() -> Bool {
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

    /// Activates MyWhoosh if running and not currently active. Returns `true` if activation was triggered.
    private static func activateMyWhooshIfNeeded() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: myWhooshBundleID).first,
              !app.isActive else {
            return false
        }
        app.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    public static func send(key: KeyCode, down: Bool, autoFocusMyWhoosh: Bool) {
        if down {
            pendingUpWork.removeValue(forKey: key)?.cancel()
            let neededActivation = autoFocusMyWhoosh && activateMyWhooshIfNeeded()
            if neededActivation {
                let targetAt = Date().addingTimeInterval(0.055)
                keyDownAt[key] = targetAt
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
                    MainActor.assumeIsolated {
                        postKeyEvent(key: key, down: true)
                    }
                }
            } else {
                keyDownAt[key] = Date()
                postKeyEvent(key: key, down: true)
            }
        } else {
            let now = Date()
            let earliestUp = (keyDownAt[key] ?? .distantPast).addingTimeInterval(minTapHoldSeconds)
            let remaining = earliestUp.timeIntervalSince(now)
            if remaining > 0.002 {
                pendingUpWork.removeValue(forKey: key)?.cancel()
                let work = DispatchWorkItem {
                    MainActor.assumeIsolated {
                        pendingUpWork.removeValue(forKey: key)
                        keyDownAt.removeValue(forKey: key)
                        postKeyEvent(key: key, down: false)
                    }
                }
                pendingUpWork[key] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            } else {
                pendingUpWork.removeValue(forKey: key)?.cancel()
                keyDownAt.removeValue(forKey: key)
                postKeyEvent(key: key, down: false)
            }
        }
    }

    public static func forceReleaseAll(_ keys: [KeyCode]) {
        for key in keys {
            pendingUpWork.removeValue(forKey: key)?.cancel()
            keyDownAt.removeValue(forKey: key)
            postKeyEvent(key: key, down: false)
        }
    }

    private static func postKeyEvent(key: KeyCode, down: Bool) {
        let vk = virtualKeyCode(for: key)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else {
            return
        }
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.post(tap: .cghidEventTap)
    }

    private static func virtualKeyCode(for key: KeyCode) -> CGKeyCode {
        switch key {
        case .i:     return CGKeyCode(kVK_ANSI_I)
        case .k:     return CGKeyCode(kVK_ANSI_K)
        case .u:     return CGKeyCode(kVK_ANSI_U)
        case .left:  return CGKeyCode(kVK_LeftArrow)
        case .right: return CGKeyCode(kVK_RightArrow)
        }
    }
}
