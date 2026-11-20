import AppKit
import Combine
import CoreBluetooth
import ZwiftBoardCore

@main
@MainActor
final class ZwiftBoardDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var ble: BLEManager!
    private var cancellables: Set<AnyCancellable> = []

    static func main() {
        let app = NSApplication.shared
        let delegate = ZwiftBoardDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ble = BLEManager()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        ble.$pods
            .combineLatest(ble.$bluetoothState)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)

        updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let readyCount = ble.pods.values.filter(\.isReady).count
        let symbolName = readyCount > 0 ? "bicycle.circle.fill" : "bicycle"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ZwiftBoard")
        button.title = readyCount > 0 ? " \(readyCount)" : ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 1. Bluetooth & Pods status
        if ble.bluetoothState != .poweredOn {
            menu.addItem(disabledItem("Bluetooth: \(btStateLabel)"))
        } else if ble.pods.isEmpty {
            menu.addItem(disabledItem("Scanning for Zwift Click… (press a button to wake)"))
        } else {
            let sorted = ble.pods.values.sorted { $0.side.rawValue < $1.side.rawValue }
            for pod in sorted {
                let bat = pod.battery.map { " · \($0)%" } ?? ""
                let state = pod.isLockedWarning ? " (Locked — Sign in to Zwift)" : (pod.isReady ? " ✓" : " …")
                menu.addItem(disabledItem("\(pod.side.displayName)\(bat)\(state)"))
            }
        }
        menu.addItem(disabledItem("Last: \(ble.lastEvent)"))
        menu.addItem(.separator())

        // 2. Accessibility permission
        if !KeySender.isAccessibilityTrusted(prompt: false) {
            let axItem = NSMenuItem(
                title: "⚠️ Grant Accessibility Permission (Required for Keys)",
                action: #selector(requestAccessibility),
                keyEquivalent: ""
            )
            axItem.target = self
            menu.addItem(axItem)
            menu.addItem(.separator())
        }

        // 3. MyWhoosh launch / focus
        let mwTitle = KeySender.isMyWhooshRunning() ? "Focus MyWhoosh" : "Launch MyWhoosh"
        let mwItem = NSMenuItem(title: mwTitle, action: #selector(launchMyWhoosh), keyEquivalent: "")
        mwItem.target = self
        menu.addItem(mwItem)

        let autoFocusItem = NSMenuItem(
            title: "Auto-Focus MyWhoosh on Click",
            action: #selector(toggleAutoFocus),
            keyEquivalent: ""
        )
        autoFocusItem.target = self
        autoFocusItem.state = ble.autoFocusMyWhoosh ? .on : .off
        menu.addItem(autoFocusItem)

        menu.addItem(.separator())

        // 4. Mode & Shift Swap
        for m in ControllerMode.allCases {
            let item = NSMenuItem(title: "Mode: \(m.rawValue)", action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = (ble.mode == m) ? .on : .off
            menu.addItem(item)
        }

        let swapItem = NSMenuItem(
            title: "Swap Shift Keys (I / K)",
            action: #selector(toggleSwapShift),
            keyEquivalent: ""
        )
        swapItem.target = self
        swapItem.state = ble.swapShiftKeys ? .on : .off
        menu.addItem(swapItem)

        menu.addItem(.separator())

        // 5. Optional Zwift Sign-In
        if ble.isSignedInToZwift {
            let signOutItem = NSMenuItem(title: "Sign Out of Zwift Unlock", action: #selector(signOutZwift), keyEquivalent: "")
            signOutItem.target = self
            menu.addItem(signOutItem)
        } else {
            let signInItem = NSMenuItem(title: "Sign In to Zwift (Unlock Left Pod)…", action: #selector(signInZwift), keyEquivalent: "")
            signInItem.target = self
            menu.addItem(signInItem)
        }

        let reconnectItem = NSMenuItem(title: "Reconnect Controllers", action: #selector(reconnectAll), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ZwiftBoard", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private var btStateLabel: String {
        switch ble.bluetoothState {
        case .poweredOff: return "Off"
        case .unauthorized: return "Permission Denied"
        case .unsupported: return "Unsupported"
        default: return "Initializing…"
        }
    }

    @objc private func requestAccessibility() {
        _ = KeySender.isAccessibilityTrusted(prompt: true)
    }

    @objc private func launchMyWhoosh() {
        KeySender.launchMyWhoosh()
    }

    @objc private func toggleAutoFocus() {
        ble.autoFocusMyWhoosh.toggle()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ControllerMode(rawValue: raw) else { return }
        ble.mode = mode
    }

    @objc private func toggleSwapShift() {
        ble.swapShiftKeys.toggle()
    }

    @objc private func reconnectAll() {
        ble.reconnectAll()
    }

    @objc private func signOutZwift() {
        Task { await ble.signOutOfZwift() }
    }

    @objc private func signInZwift() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sign In to Zwift (Optional Unlock)"
        alert.informativeText = "Only needed if the Left pod shows Locked. Credentials are sent directly to Zwift to obtain a session token and are never stored."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        stack.orientation = .vertical
        stack.spacing = 8

        let emailField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        emailField.placeholderString = "Zwift Email"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        passField.placeholderString = "Password"

        stack.addArrangedSubview(emailField)
        stack.addArrangedSubview(passField)
        alert.accessoryView = stack

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passField.stringValue
        guard !email.isEmpty, !password.isEmpty else { return }

        Task {
            do {
                try await ble.signInToZwift(email: email, password: password)
            } catch {
                let errAlert = NSAlert()
                errAlert.messageText = "Zwift Sign-In Failed"
                errAlert.informativeText = error.localizedDescription
                errAlert.runModal()
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
