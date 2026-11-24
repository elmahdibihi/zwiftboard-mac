import AppKit
import Combine
import CoreBluetooth
import OSLog
import ZwiftBoardCore

@main
@MainActor
final class ZwiftBoardDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var ble: BLEManager!
    private var testWindowController: TestWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "com.zwiftboard.mac", category: "lifecycle")

    private var myWhooshWasRunning = false
    private var lastUserActivityAt = Date()
    private var lifecycleTimer: Timer?
    private var isQuitting = false

    private static let bundleID = "com.zwiftboard.mac"
    private static let showTestWindowNotification = Notification.Name("com.zwiftboard.mac.showTestWindow")
    private static let idleWithoutMyWhooshTimeout: TimeInterval = 900 // 15 min

    static func main() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }
        if !others.isEmpty {
            // Ask the running instance to open the Test & Auto-Fix window, then exit cleanly
            DistributedNotificationCenter.default().postNotificationName(
                showTestWindowNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = ZwiftBoardDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ble = BLEManager()
        ble.onButtonActivity = { [weak self] in
            self?.lastUserActivityAt = Date()
        }
        myWhooshWasRunning = KeySender.isMyWhooshRunning()
        lastUserActivityAt = Date()
        logger.info("Launched axTrusted=\(KeySender.isAccessibilityTrusted(prompt: false)) myWhooshRunning=\(self.myWhooshWasRunning)")

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

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            self,
            selector: #selector(workspaceAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(workspaceAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(openTestWindow),
            name: Self.showTestWindowNotification,
            object: nil
        )

        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkMyWhooshLifecycle()
            }
        }

        updateStatusButton()

        // If launched before MyWhoosh is open (pre-ride), open the Test & Auto-Fix window automatically
        if !myWhooshWasRunning {
            openTestWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleTimer?.invalidate()
        ble?.disconnectAll()
    }

    @objc private func workspaceAppLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == KeySender.myWhooshBundleID else { return }
        myWhooshWasRunning = true
        if !ble.isScanning && ble.pods.isEmpty {
            ble.startScanning()
        }
    }

    @objc private func workspaceAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == KeySender.myWhooshBundleID else { return }
        checkMyWhooshLifecycle()
    }

    private func checkMyWhooshLifecycle() {
        guard !isQuitting else { return }
        let running = KeySender.isMyWhooshRunning()
        if running {
            myWhooshWasRunning = true
            lastUserActivityAt = Date()
            return
        }
        if myWhooshWasRunning || Date().timeIntervalSince(lastUserActivityAt) >= Self.idleWithoutMyWhooshTimeout {
            shutdownWithDisconnect(reason: myWhooshWasRunning ? "MyWhoosh closed" : "Idle timeout without MyWhoosh")
        }
    }

    private func shutdownWithDisconnect(reason: String) {
        guard !isQuitting else { return }
        isQuitting = true
        logger.info("Shutting down: \(reason, privacy: .public)")
        lifecycleTimer?.invalidate()
        ble.disconnectAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.terminate(nil)
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let readyCount = ble.pods.values.filter(\.isReady).count
        let symbolName = readyCount > 0 ? "bicycle.circle.fill" : "bicycle"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ZwiftBoard")
        button.title = readyCount > 0 ? " \(readyCount)" : ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        lastUserActivityAt = Date()
        menu.removeAllItems()

        // 1. Bluetooth & Pods status
        if ble.bluetoothState == .unauthorized {
            let btItem = NSMenuItem(
                title: "⚠️ Allow Bluetooth in System Settings…",
                action: #selector(openBluetoothSettings),
                keyEquivalent: ""
            )
            btItem.target = self
            menu.addItem(btItem)
            menu.addItem(.separator())
        } else if ble.bluetoothState != .poweredOn {
            menu.addItem(disabledItem("Bluetooth: \(btStateLabel)"))
        } else if ble.pods.isEmpty {
            menu.addItem(disabledItem("Scanning for Zwift Click… (press a button to wake)"))
        } else {
            let sorted = ble.pods.values.sorted { $0.side.rawValue < $1.side.rawValue }
            for pod in sorted {
                let bat = pod.battery.map { " · \($0)%" } ?? ""
                let state: String
                if pod.isReconnecting {
                    state = " (Reconnecting…)"
                } else if pod.isReady {
                    state = pod.needsZwiftSignInHint ? " ✓ (Sign in if '−' locks)" : " ✓"
                } else {
                    state = " …"
                }
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

            let axSettingsItem = NSMenuItem(
                title: "Open Accessibility Settings…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            axSettingsItem.target = self
            menu.addItem(axSettingsItem)
            menu.addItem(.separator())
        }

        // 3. Test & Auto-Fix + MyWhoosh launch / focus
        let testItem = NSMenuItem(
            title: "Test & Auto-Fix Setup…",
            action: #selector(openTestWindow),
            keyEquivalent: "t"
        )
        testItem.target = self
        menu.addItem(testItem)

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

        // 4. Keymap Presets & Active Summary
        for line in MyWhooshKeymap.summaryLines(preset: ble.preset, swapShift: ble.swapShiftKeys) {
            menu.addItem(disabledItem("  \(line)"))
        }

        for p in KeymapPreset.allCases {
            let item = NSMenuItem(title: "Mapping: \(p.rawValue)", action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.rawValue
            item.state = (ble.preset == p) ? .on : .off
            menu.addItem(item)
        }

        let swapItem = NSMenuItem(
            title: "Swap Shift Direction (+ Easier / − Harder)",
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

    @objc private func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func requestAccessibility() {
        if !KeySender.isAccessibilityTrusted(prompt: true) {
            openAccessibilitySettings()
        }
    }

    @objc private func openTestWindow() {
        lastUserActivityAt = Date()
        if testWindowController == nil {
            testWindowController = TestWindowController(ble: ble)
        }
        testWindowController?.showWindowAndActivate()
    }

    @objc private func launchMyWhoosh() {
        lastUserActivityAt = Date()
        KeySender.launchMyWhoosh()
    }

    @objc private func toggleAutoFocus() {
        ble.autoFocusMyWhoosh.toggle()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = KeymapPreset(rawValue: raw) else { return }
        ble.preset = preset
    }

    @objc private func toggleSwapShift() {
        ble.swapShiftKeys.toggle()
    }

    @objc private func reconnectAll() {
        lastUserActivityAt = Date()
        ble.reconnectAll()
    }

    @objc private func signOutZwift() {
        Task { await ble.signOutOfZwift() }
    }

    @objc private func signInZwift() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sign In to Zwift (Optional Unlock)"
        alert.informativeText = "Only needed if the Left pod's minus/arrow buttons lock after ~1 minute. Right pod (+ / B / Y) works without signing in. Credentials are sent directly to Zwift and are never stored."
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
        shutdownWithDisconnect(reason: "User quit")
    }
}
