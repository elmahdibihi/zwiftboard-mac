import AppKit
import Carbon.HIToolbox
import Combine
import CoreBluetooth
import ZwiftBoardCore

@MainActor
final class TestWindowController: NSWindowController, NSWindowDelegate {
    private let ble: BLEManager
    private var cancellables: Set<AnyCancellable> = []
    private var pollTimer: Timer?
    private var keyMonitor: Any?
    private var pendingKeyCheckWork: DispatchWorkItem?
    private var awaitingKeySince: Date?

    private var simulatedGear: Int = 15

    private let btStatusLabel = NSTextField(labelWithString: "")
    private let btFixButton = NSButton(title: "Fix Bluetooth", target: nil, action: nil)

    private let axStatusLabel = NSTextField(labelWithString: "")
    private let axFixButton = NSButton(title: "Repair Accessibility", target: nil, action: nil)

    private let podsStatusLabel = NSTextField(labelWithString: "")
    private let bleFixButton = NSButton(title: "Reconnect Pods", target: nil, action: nil)

    private let gearLabel = NSTextField(labelWithString: "GEAR 15")
    private let stage1Label = NSTextField(labelWithString: "1. BLE Signal: Waiting for button press…")
    private let stage2Label = NSTextField(labelWithString: "2. macOS Keystroke: Waiting…")
    private let verdictBanner = NSTextField(wrappingLabelWithString: "Press + or B / − on your Zwift Click to verify shifting end-to-end before opening MyWhoosh.")

    init(ble: BLEManager) {
        self.ble = ble
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "ZwiftBoard — Test & Auto-Fix"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        super.init(window: win)
        win.delegate = self
        buildUI(in: win)
        bindState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindowAndActivate() {
        ble.suppressAutoFocus = true
        installKeyMonitorIfNeeded()
        startPollingIfNeeded()
        refreshStatusUI()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        cleanupActiveHooks()
    }

    private func cleanupActiveHooks() {
        ble.suppressAutoFocus = false
        pollTimer?.invalidate()
        pollTimer = nil
        pendingKeyCheckWork?.cancel()
        pendingKeyCheckWork = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func buildUI(in win: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Pre-Ride Check & Auto-Fix")
        header.font = .systemFont(ofSize: 18, weight: .bold)
        root.addArrangedSubview(header)

        // Checklist Box
        let checkBox = NSBox()
        checkBox.title = "System & Controller Health"
        checkBox.titlePosition = .atTop
        checkBox.translatesAutoresizingMaskIntoConstraints = false

        let checkStack = NSStackView()
        checkStack.orientation = .vertical
        checkStack.alignment = .leading
        checkStack.spacing = 10
        checkStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        checkStack.translatesAutoresizingMaskIntoConstraints = false

        btFixButton.target = self
        btFixButton.action = #selector(fixBluetooth)
        btFixButton.bezelStyle = .rounded
        btFixButton.controlSize = .small

        axFixButton.target = self
        axFixButton.action = #selector(repairAccessibility)
        axFixButton.bezelStyle = .rounded
        axFixButton.controlSize = .small

        bleFixButton.target = self
        bleFixButton.action = #selector(reconnectPods)
        bleFixButton.bezelStyle = .rounded
        bleFixButton.controlSize = .small

        checkStack.addArrangedSubview(makeCheckRow(label: btStatusLabel, button: btFixButton))
        checkStack.addArrangedSubview(makeCheckRow(label: axStatusLabel, button: axFixButton))
        checkStack.addArrangedSubview(makeCheckRow(label: podsStatusLabel, button: bleFixButton))

        checkBox.contentView = checkStack
        root.addArrangedSubview(checkBox)

        // Live Shift Simulator Box
        let simBox = NSBox()
        simBox.title = "End-to-End Shift Simulator (MyWhoosh Preview)"
        simBox.titlePosition = .atTop
        simBox.translatesAutoresizingMaskIntoConstraints = false

        let simStack = NSStackView()
        simStack.orientation = .vertical
        simStack.alignment = .centerX
        simStack.spacing = 8
        simStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        simStack.translatesAutoresizingMaskIntoConstraints = false

        gearLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .heavy)
        gearLabel.alignment = .center

        stage1Label.font = .systemFont(ofSize: 12, weight: .medium)
        stage1Label.textColor = .secondaryLabelColor
        stage2Label.font = .systemFont(ofSize: 12, weight: .medium)
        stage2Label.textColor = .secondaryLabelColor

        verdictBanner.font = .systemFont(ofSize: 12.5, weight: .semibold)
        verdictBanner.alignment = .center
        verdictBanner.maximumNumberOfLines = 3

        simStack.addArrangedSubview(gearLabel)
        simStack.addArrangedSubview(stage1Label)
        simStack.addArrangedSubview(stage2Label)
        simStack.addArrangedSubview(verdictBanner)

        simBox.contentView = simStack
        root.addArrangedSubview(simBox)

        // Footer Buttons
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let autoFixAllBtn = NSButton(title: "Auto-Fix Issues", target: self, action: #selector(runAutoFixAll))
        autoFixAllBtn.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        closeBtn.bezelStyle = .rounded

        let launchBtn = NSButton(title: "Launch MyWhoosh →", target: self, action: #selector(launchMyWhooshAndClose))
        launchBtn.bezelStyle = .rounded
        launchBtn.keyEquivalent = "\r"

        footer.addArrangedSubview(autoFixAllBtn)
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(closeBtn)
        footer.addArrangedSubview(launchBtn)
        root.addArrangedSubview(footer)

        let container = NSView()
        container.addSubview(root)
        win.contentView = container

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            checkBox.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            simBox.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            verdictBanner.widthAnchor.constraint(equalToConstant: 400),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40)
        ])
    }

    private func makeCheckRow(label: NSTextField, button: NSButton) -> NSStackView {
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, spacer, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 416).isActive = true
        return row
    }

    private func bindState() {
        ble.$pods
            .combineLatest(ble.$bluetoothState)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refreshStatusUI()
            }
            .store(in: &cancellables)

        ble.$lastButtonDiagnostic
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.handleBLEDiagnostic(event)
            }
            .store(in: &cancellables)
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatusUI()
            }
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isVisible == true else { return event }
            if self.handleReceivedKeyDown(event) {
                return nil // consume test key so macOS does not play NSBeep
            }
            return event
        }
    }

    private func refreshStatusUI() {
        // 1. Bluetooth
        switch ble.bluetoothState {
        case .poweredOn:
            btStatusLabel.stringValue = "✓ Bluetooth: Powered On"
            btStatusLabel.textColor = .systemGreen
            btFixButton.isHidden = true
        case .unauthorized:
            btStatusLabel.stringValue = "✗ Bluetooth: Permission Denied"
            btStatusLabel.textColor = .systemRed
            btFixButton.isHidden = false
        case .poweredOff:
            btStatusLabel.stringValue = "✗ Bluetooth: Turned Off"
            btStatusLabel.textColor = .systemRed
            btFixButton.isHidden = false
        default:
            btStatusLabel.stringValue = "… Bluetooth: Initializing"
            btStatusLabel.textColor = .secondaryLabelColor
            btFixButton.isHidden = true
        }

        // 2. Accessibility
        let axOK = KeySender.isAccessibilityTrusted(prompt: false)
        if axOK {
            axStatusLabel.stringValue = "✓ Accessibility: Enabled (Keys Active)"
            axStatusLabel.textColor = .systemGreen
            axFixButton.title = "Re-check"
            axFixButton.isHidden = true
        } else {
            axStatusLabel.stringValue = "✗ Accessibility: Blocked (Click Repair →)"
            axStatusLabel.textColor = .systemOrange
            axFixButton.title = "Repair Accessibility"
            axFixButton.isHidden = false
        }

        // 3. Pods
        let readyPods = ble.pods.values.filter(\.isReady)
        if readyPods.isEmpty {
            podsStatusLabel.stringValue = "… Controllers: Scanning (press + on Click to wake)"
            podsStatusLabel.textColor = .secondaryLabelColor
        } else {
            let summary = readyPods
                .sorted { $0.side.rawValue < $1.side.rawValue }
                .map { p in
                    let bat = p.battery.map { " \($0)%" } ?? ""
                    return "\(p.side.displayName)\(bat) ✓"
                }
                .joined(separator: "  ·  ")
            podsStatusLabel.stringValue = "✓ \(summary)"
            podsStatusLabel.textColor = .systemGreen
        }
    }

    private func handleBLEDiagnostic(_ event: BLEManager.ButtonDiagnosticEvent) {
        guard window?.isVisible == true else { return }
        guard let mapped = event.mappedKey else {
            stage1Label.stringValue = "1. BLE Signal: ✓ Received \(event.button.rawValue) (Unmapped in current preset)"
            stage1Label.textColor = .systemGreen
            stage2Label.stringValue = "2. macOS Keystroke: Ignored by preset"
            stage2Label.textColor = .secondaryLabelColor
            return
        }

        stage1Label.stringValue = "1. BLE Signal: ✓ Received \(event.button.rawValue)"
        stage1Label.textColor = .systemGreen
        stage2Label.stringValue = "2. macOS Keystroke: Waiting for \(mapped.displayLabel)…"
        stage2Label.textColor = .secondaryLabelColor

        awaitingKeySince = Date()
        pendingKeyCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.awaitingKeySince != nil else { return }
                self.awaitingKeySince = nil
                self.stage2Label.stringValue = "2. macOS Keystroke: ✗ Did NOT arrive in window"
                self.stage2Label.textColor = .systemRed
                if !KeySender.isAccessibilityTrusted(prompt: false) {
                    self.verdictBanner.stringValue = "⚠️ BLE works, but macOS blocked the keystroke! Click 'Repair Accessibility' above and enable ZwiftBoard."
                } else {
                    self.verdictBanner.stringValue = "⚠️ BLE works, but keystroke was blocked (stale macOS permission). Click 'Auto-Fix Issues' below to reset & re-enable Accessibility."
                    self.axFixButton.isHidden = false
                }
                self.verdictBanner.textColor = .systemOrange
            }
        }
        pendingKeyCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func handleReceivedKeyDown(_ event: NSEvent) -> Bool {
        let actionDesc: String
        switch Int(event.keyCode) {
        case kVK_ANSI_K:
            simulatedGear = min(30, simulatedGear + 1)
            gearLabel.stringValue = "GEAR \(simulatedGear) ▲"
            actionDesc = "K → Shifted UP to Gear \(simulatedGear)"
        case kVK_ANSI_I:
            simulatedGear = max(1, simulatedGear - 1)
            gearLabel.stringValue = "GEAR \(simulatedGear) ▼"
            actionDesc = "I → Shifted DOWN to Gear \(simulatedGear)"
        case kVK_LeftArrow:
            gearLabel.stringValue = "◀ STEER LEFT"
            actionDesc = "← Steer Left"
        case kVK_RightArrow:
            gearLabel.stringValue = "STEER RIGHT ▶"
            actionDesc = "→ Steer Right"
        case kVK_ANSI_U:
            gearLabel.stringValue = "HUD TOGGLE"
            actionDesc = "U → Toggle HUD"
        default:
            return false
        }

        awaitingKeySince = nil
        pendingKeyCheckWork?.cancel()
        pendingKeyCheckWork = nil

        stage2Label.stringValue = "2. macOS Keystroke: ✓ Delivered (\(actionDesc))"
        stage2Label.textColor = .systemGreen
        verdictBanner.stringValue = "✓ VERIFIED END-TO-END! BLE + macOS keystrokes are working. Click 'Launch MyWhoosh →' whenever you're ready."
        verdictBanner.textColor = .systemGreen
        return true
    }

    @objc private func fixBluetooth() {
        if ble.bluetoothState == .unauthorized {
            runTCCReset(service: "BluetoothAlways")
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func repairAccessibility() {
        // Reset stale ad-hoc TCC entry first so macOS registers the exact running binary cleanly
        runTCCReset(service: "Accessibility")
        _ = KeySender.isAccessibilityTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        verdictBanner.stringValue = "Toggle 'ZwiftBoard' ON in the System Settings window that just opened, then press + on your Click again."
        verdictBanner.textColor = .labelColor
        refreshStatusUI()
    }

    @objc private func reconnectPods() {
        stage1Label.stringValue = "1. BLE Signal: Reconnecting… (press a button on Click to wake)"
        stage1Label.textColor = .secondaryLabelColor
        ble.reconnectAll()
        refreshStatusUI()
    }

    @objc private func runAutoFixAll() {
        if ble.bluetoothState == .unauthorized {
            fixBluetooth()
        }
        if !KeySender.isAccessibilityTrusted(prompt: false) || verdictBanner.textColor == .systemOrange {
            repairAccessibility()
        }
        ble.reconnectAll()
        refreshStatusUI()
    }

    private func runTCCReset(service: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", service, "com.zwiftboard.mac"]
        try? proc.run()
        proc.waitUntilExit()
    }

    @objc private func closeSheet() {
        cleanupActiveHooks()
        window?.close()
    }

    @objc private func launchMyWhooshAndClose() {
        cleanupActiveHooks()
        window?.close()
        KeySender.launchMyWhoosh()
    }
}
