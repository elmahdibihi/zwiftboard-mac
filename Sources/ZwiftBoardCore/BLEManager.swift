@preconcurrency import CoreBluetooth
import Foundation
import OSLog

@MainActor
public final class BLEManager: NSObject, ObservableObject {
    public struct PodStatus: Identifiable, Sendable {
        public let id: UUID
        public var name: String
        public var side: ZwiftProtocol.PodSide
        public var battery: Int?
        public var isReady: Bool
        public var isReconnecting: Bool
        public var needsZwiftSignInHint: Bool
    }

    public struct ButtonDiagnosticEvent: Equatable, Sendable {
        public let id = UUID()
        public let button: ZwiftProtocol.Button
        public let mappedKey: KeyCode?
        public let timestamp = Date()
    }

    private let logger = Logger(subsystem: "com.zwiftboard.mac", category: "ble")

    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var pods: [UUID: PodStatus] = [:]
    @Published public private(set) var lastEvent: String = "Waiting for Zwift Click…"
    @Published public private(set) var lastButtonDiagnostic: ButtonDiagnosticEvent?
    @Published public private(set) var isSignedInToZwift: Bool = false

    /// Set true while the Test & Auto-Fix window is open so test keystrokes stay in the test window.
    public var suppressAutoFocus: Bool = false

    @Published public var preset: KeymapPreset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: "ZwiftBoard.Preset")
            releaseAllHeldKeys()
        }
    }
    @Published public var swapShiftKeys: Bool {
        didSet {
            UserDefaults.standard.set(swapShiftKeys, forKey: "ZwiftBoard.SwapShift")
            releaseAllHeldKeys()
        }
    }
    @Published public var autoFocusMyWhoosh: Bool {
        didSet { UserDefaults.standard.set(autoFocusMyWhoosh, forKey: "ZwiftBoard.AutoFocus") }
    }

    public var onButtonActivity: (() -> Void)?

    public let unlockClient = ZwiftUnlockClient()
    private let holdTracker = HoldTracker()

    private var central: CBCentralManager!
    private var activeEnabled: Bool = true
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var sessions: [UUID: PodSession] = [:]
    private var scanCycleTimer: Timer?
    private var scanBurstStopWork: DispatchWorkItem?

    private let asyncUUID = CBUUID(string: ZwiftProtocol.asyncUUIDString)
    private let syncRXUUID = CBUUID(string: ZwiftProtocol.syncRXUUIDString)
    private let syncTXUUID = CBUUID(string: ZwiftProtocol.syncTXUUIDString)
    private let batteryLevelUUID = CBUUID(string: ZwiftProtocol.batteryLevelUUIDString)

    private static let idleResetSeconds: TimeInterval = 55.0
    private static let postResetGraceSeconds: TimeInterval = 12.0
    private static let ackIntervalSeconds: TimeInterval = 15.0
    private static let connectTimeoutSeconds: TimeInterval = 10.0

    private struct PodSession {
        let sessionID = UUID()
        var side: ZwiftProtocol.PodSide
        var asyncChar: CBCharacteristic?
        var syncRXChar: CBCharacteristic?
        var syncTXChar: CBCharacteristic?
        var pressedButtons: Set<ZwiftProtocol.Button> = []
        var activeButtonKeys: [ZwiftProtocol.Button: KeyCode] = [:]
        var handshakeSent = false
        var rideOnEchoed = false
        var lastInboundAt = Date()
        var lastAckAt: Date?
        var resetSent = false
        var resetAt: Date?
        var tickCount = 0
        var challengeSeq = 0
        var keepaliveTimer: Timer?
        var connectWatchdog: Timer?
    }

    public override init() {
        let savedPreset = UserDefaults.standard.string(forKey: "ZwiftBoard.Preset")
        self.preset = KeymapPreset(rawValue: savedPreset ?? "") ?? .shiftingOnly
        self.swapShiftKeys = UserDefaults.standard.bool(forKey: "ZwiftBoard.SwapShift")
        if UserDefaults.standard.object(forKey: "ZwiftBoard.AutoFocus") == nil {
            self.autoFocusMyWhoosh = true
        } else {
            self.autoFocusMyWhoosh = UserDefaults.standard.bool(forKey: "ZwiftBoard.AutoFocus")
        }
        super.init()
        self.central = CBCentralManager(delegate: self, queue: .main)
        Task {
            self.isSignedInToZwift = await unlockClient.isSignedIn
        }
    }

    private var bothSidesReady: Bool {
        let readySides = Set(pods.values.filter(\.isReady).map(\.side))
        return readySides.contains(.left) && readySides.contains(.right)
    }

    public func startScanning() {
        activeEnabled = true
        guard central.state == .poweredOn else { return }
        ensureScanLoopRunning()
        runScanBurstIfNeeded()
    }

    private func ensureScanLoopRunning() {
        guard scanCycleTimer == nil else { return }
        scanCycleTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runScanBurstIfNeeded()
            }
        }
    }

    private func runScanBurstIfNeeded() {
        guard activeEnabled, central.state == .poweredOn else {
            stopScanningOnly()
            return
        }
        // Pause active scanning once both Left & Right pods are ready to save BLE bandwidth
        if bothSidesReady {
            stopScanningOnly()
            return
        }
        scanBurstStopWork?.cancel()
        central.stopScan()
        isScanning = true
        if pods.isEmpty {
            lastEvent = "Scanning for Zwift Click…"
        }
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])

        let stopWork = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isScanning else { return }
                self.central.stopScan()
                self.isScanning = false
            }
        }
        scanBurstStopWork = stopWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: stopWork)
    }

    private func stopScanningOnly() {
        scanBurstStopWork?.cancel()
        scanBurstStopWork = nil
        if isScanning {
            central.stopScan()
            isScanning = false
        }
    }

    public func disconnectAll() {
        activeEnabled = false
        scanCycleTimer?.invalidate()
        scanCycleTimer = nil
        stopScanningOnly()

        let activePeripherals = Array(peripherals.values)
        for session in sessions.values {
            session.keepaliveTimer?.invalidate()
            session.connectWatchdog?.invalidate()
        }
        releaseAllHeldKeys()
        peripherals.removeAll()
        sessions.removeAll()
        pods.removeAll()
        for p in activePeripherals {
            central.cancelPeripheralConnection(p)
        }
        lastEvent = "Disconnected"
        logger.info("Disconnected all peripherals")
    }

    public func reconnectAll() {
        disconnectAll()
        activeEnabled = true
        startScanning()
    }

    private func releaseAllHeldKeys() {
        let lifted = holdTracker.releaseAllGlobal()
        for id in sessions.keys {
            sessions[id]?.activeButtonKeys.removeAll()
        }
        if !lifted.isEmpty {
            KeySender.forceReleaseAll(lifted)
        }
    }

    public func signInToZwift(email: String, password: String) async throws {
        try await unlockClient.login(email: email, password: password)
        isSignedInToZwift = true
        // Recycle Left pod session so it re-challenges and receives the server-signed unlock
        for (id, session) in sessions where session.side == .left {
            recyclePeripheral(id: id, reason: "Zwift sign-in completed")
        }
    }

    public func signOutOfZwift() async {
        await unlockClient.signOut()
        isSignedInToZwift = false
    }

    private func connectPeripheral(_ peripheral: CBPeripheral, side: ZwiftProtocol.PodSide, displayName: String) {
        guard activeEnabled, central.state == .poweredOn else { return }
        let id = peripheral.identifier
        peripherals[id] = peripheral
        peripheral.delegate = self

        sessions[id]?.keepaliveTimer?.invalidate()
        sessions[id]?.connectWatchdog?.invalidate()

        var newSession = PodSession(side: side)
        newSession.connectWatchdog = Timer.scheduledTimer(withTimeInterval: Self.connectTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.sessions[id], !s.handshakeSent else { return }
                self.recyclePeripheral(id: id, reason: "Connect/discovery timeout")
            }
        }
        sessions[id] = newSession

        if var existing = pods[id] {
            existing.isReady = false
            existing.isReconnecting = true
            if side != .unknown { existing.side = side }
            pods[id] = existing
        } else {
            pods[id] = PodStatus(
                id: id,
                name: displayName,
                side: side,
                battery: nil,
                isReady: false,
                isReconnecting: false,
                needsZwiftSignInHint: false
            )
        }

        central.connect(peripheral, options: nil)
    }

    private func recyclePeripheral(id: UUID, reason: String) {
        logger.info("Recycling peripheral: \(reason, privacy: .public)")
        teardownSessionState(for: id)
        guard activeEnabled, let peripheral = peripherals[id] else { return }
        pods[id]?.isReady = false
        pods[id]?.isReconnecting = true
        central.cancelPeripheralConnection(peripheral)
        // Re-arm OS-level auto-connect + scan burst after brief settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activeEnabled, let p = self.peripherals[id] else { return }
                if p.state != .connected && p.state != .connecting {
                    let side = self.pods[id]?.side ?? .unknown
                    let name = self.pods[id]?.name ?? side.displayName
                    self.connectPeripheral(p, side: side, displayName: name)
                }
                self.runScanBurstIfNeeded()
            }
        }
    }

    private func teardownSessionState(for id: UUID) {
        if let session = sessions.removeValue(forKey: id) {
            session.keepaliveTimer?.invalidate()
            session.connectWatchdog?.invalidate()
            let lifted = holdTracker.releaseAll(sessionID: session.sessionID)
            if !lifted.isEmpty {
                KeySender.forceReleaseAll(lifted)
            }
        }
    }

    private func writeSyncRX(_ data: Data, to peripheral: CBPeripheral, char: CBCharacteristic) {
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: char, type: writeType)
    }

    private func sendActivationIfReady(for id: UUID, peripheral: CBPeripheral) {
        guard var session = sessions[id],
              !session.handshakeSent,
              let asyncChar = session.asyncChar,
              let syncRX = session.syncRXChar else { return }

        session.handshakeSent = true
        session.connectWatchdog?.invalidate()
        session.connectWatchdog = nil
        session.lastInboundAt = Date()
        session.resetSent = false
        session.resetAt = nil
        session.keepaliveTimer?.invalidate()

        peripheral.setNotifyValue(true, for: asyncChar)
        if let syncTX = session.syncTXChar {
            peripheral.setNotifyValue(true, for: syncTX)
        }

        for (idx, frame) in ZwiftProtocol.activationFrames.enumerated() {
            let delay = Double(idx) * 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
                MainActor.assumeIsolated {
                    guard let self, let peripheral, self.sessions[id] != nil else { return }
                    self.writeSyncRX(frame, to: peripheral, char: syncRX)
                }
            }
        }

        session.keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keepaliveTick(for: id)
            }
        }
        sessions[id] = session

        pods[id]?.isReady = true
        pods[id]?.isReconnecting = false
        if bothSidesReady {
            stopScanningOnly()
        }
    }

    private func keepaliveTick(for id: UUID) {
        guard activeEnabled,
              let peripheral = peripherals[id],
              var s = sessions[id],
              let rx = s.syncRXChar else { return }

        if peripheral.state != .connected {
            recyclePeripheral(id: id, reason: "Peripheral state no longer connected")
            return
        }

        let now = Date()
        s.tickCount += 1

        // Every 6s, probe link health via HCI RSSI read (catches silent link drops)
        if s.tickCount % 2 == 0 {
            peripheral.readRSSI()
        }

        // 1. Post-reset zombie check: if we sent 0x18 and heard ZERO frames for 12s, recycle for fresh connect
        if s.resetSent, let resetAt = s.resetAt,
           now.timeIntervalSince(resetAt) >= Self.postResetGraceSeconds,
           s.lastInboundAt < resetAt {
            sessions[id] = s
            recyclePeripheral(id: id, reason: "Silent past scheduled 0x18 reset")
            return
        }

        // 2. Proactive 0x18 reboot at 55s of inbound silence (prevents ~65s deep-sleep stranding)
        if !s.resetSent && now.timeIntervalSince(s.lastInboundAt) >= Self.idleResetSeconds {
            s.resetSent = true
            s.resetAt = now
            sessions[id] = s
            writeSyncRX(ZwiftProtocol.resetPod, to: peripheral, char: rx)
            return
        }

        // 3. Periodic empty ack (ff 04 00) every 15s when not signed in
        if !isSignedInToZwift, let ackAt = s.lastAckAt,
           now.timeIntervalSince(ackAt) >= Self.ackIntervalSeconds {
            s.lastAckAt = now
            sessions[id] = s
            writeSyncRX(ZwiftProtocol.emptyAck, to: peripheral, char: rx)
            return
        }

        sessions[id] = s
        writeSyncRX(ZwiftProtocol.rideOn, to: peripheral, char: rx)
    }

    private func touchInboundActivity(for id: UUID, peripheral: CBPeripheral) {
        guard var s = sessions[id] else { return }
        let wasResetSent = s.resetSent
        s.lastInboundAt = Date()
        s.resetSent = false
        s.resetAt = nil
        if wasResetSent {
            // Pod revived on a maintained link after 0x18 without disconnecting: re-run handshake
            s.handshakeSent = false
            sessions[id] = s
            sendActivationIfReady(for: id, peripheral: peripheral)
        } else {
            sessions[id] = s
        }
    }

    private func handleChallenge(_ frame: Data, peripheral: CBPeripheral, syncRX: CBCharacteristic) {
        let id = peripheral.identifier
        guard var s = sessions[id] else { return }
        s.challengeSeq += 1
        let seq = s.challengeSeq
        sessions[id] = s

        guard let payload = ZwiftProtocol.challengePayload(fromFrame: frame) else {
            writeSyncRX(ZwiftProtocol.emptyAck, to: peripheral, char: syncRX)
            sessions[id]?.lastAckAt = Date()
            return
        }

        let side = pods[id]?.side
        Task {
            let signed = await unlockClient.isSignedIn
            if !signed {
                await MainActor.run {
                    guard self.sessions[id]?.challengeSeq == seq else { return }
                    self.writeSyncRX(ZwiftProtocol.emptyAck, to: peripheral, char: syncRX)
                    self.sessions[id]?.lastAckAt = Date()
                    if side == .left {
                        self.pods[id]?.needsZwiftSignInHint = true
                    }
                }
                return
            }
            do {
                let reply = try await unlockClient.solve(challenge: payload)
                let responseFrame = ZwiftProtocol.emptyAck + reply
                await MainActor.run {
                    guard self.sessions[id]?.challengeSeq == seq else { return }
                    self.writeSyncRX(responseFrame, to: peripheral, char: syncRX)
                    self.sessions[id]?.lastAckAt = Date()
                    self.pods[id]?.needsZwiftSignInHint = false
                    self.pods[id]?.isReady = true
                }
            } catch {
                await MainActor.run {
                    guard self.sessions[id]?.challengeSeq == seq else { return }
                    self.writeSyncRX(ZwiftProtocol.emptyAck, to: peripheral, char: syncRX)
                    self.sessions[id]?.lastAckAt = Date()
                    self.lastEvent = "Unlock fallback (\(error.localizedDescription))"
                }
            }
        }
    }

    private func handleAsyncFrame(_ data: Data, for id: UUID) {
        guard let nextButtons = ZwiftProtocol.pressedButtons(fromAsyncFrame: data),
              var session = sessions[id] else { return }

        let prevButtons = session.pressedButtons
        session.pressedButtons = nextButtons

        let newlyPressed = nextButtons.subtracting(prevButtons)
        let newlyReleased = prevButtons.subtracting(nextButtons)

        if !newlyPressed.isEmpty {
            onButtonActivity?()
        }

        for btn in newlyPressed {
            let mapped = MyWhooshKeymap.key(for: btn, preset: preset, swapShift: swapShiftKeys)
            lastButtonDiagnostic = ButtonDiagnosticEvent(button: btn, mappedKey: mapped)
            if let key = mapped {
                session.activeButtonKeys[btn] = key
                if holdTracker.press(key: key, sessionID: session.sessionID) {
                    let shouldFocus = autoFocusMyWhoosh && !suppressAutoFocus
                    KeySender.send(key: key, down: true, autoFocusMyWhoosh: shouldFocus)
                    lastEvent = "\(btn.rawValue) → \(key.displayLabel)"
                }
            } else {
                lastEvent = "\(btn.rawValue) (ignored in \(preset == .shiftingOnly ? "Shifting Only" : "Steering"))"
            }
        }

        for btn in newlyReleased {
            if let key = session.activeButtonKeys.removeValue(forKey: btn) {
                if holdTracker.release(key: key, sessionID: session.sessionID) {
                    KeySender.send(key: key, down: false, autoFocusMyWhoosh: false)
                }
            }
        }

        sessions[id] = session
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            let state = central.state
            self.bluetoothState = state
            self.logger.info("BLE state changed: \(state.rawValue)")
            if state == .poweredOn && self.activeEnabled {
                // Reconnect any known peripherals and start burst scanner
                for (id, p) in self.peripherals where p.state != .connected && p.state != .connecting {
                    let side = self.pods[id]?.side ?? .unknown
                    let name = self.pods[id]?.name ?? side.displayName
                    self.connectPeripheral(p, side: side, displayName: name)
                }
                self.startScanning()
            } else {
                self.stopScanningOnly()
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let deviceID = mfgData.flatMap { ZwiftProtocol.deviceID(fromManufacturerData: $0) }
        let isZwift = deviceID != nil || localName.lowercased().hasPrefix("zwift")
        guard isZwift else { return }

        let side = deviceID.map { ZwiftProtocol.PodSide(deviceID: $0) } ?? .unknown

        MainActor.assumeIsolated {
            guard self.activeEnabled else { return }
            let id = peripheral.identifier
            if let existing = self.peripherals[id] {
                if side != .unknown { self.pods[id]?.side = side }
                if existing.state != .connected && existing.state != .connecting {
                    let disp = localName.isEmpty ? side.displayName : localName
                    self.connectPeripheral(existing, side: side, displayName: disp)
                }
                return
            }
            let disp = localName.isEmpty ? side.displayName : localName
            self.logger.info("Discovered \(side.displayName, privacy: .public)")
            self.lastEvent = "Connecting to \(side.displayName)…"
            self.connectPeripheral(peripheral, side: side, displayName: disp)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard self.activeEnabled else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverServices(nil)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            self.recyclePeripheral(id: id, reason: "Failed to connect")
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            self.teardownSessionState(for: id)
            guard self.activeEnabled else {
                self.peripherals.removeValue(forKey: id)
                self.pods.removeValue(forKey: id)
                return
            }
            self.pods[id]?.isReady = false
            self.pods[id]?.isReconnecting = true
            self.lastEvent = "\(self.pods[id]?.side.displayName ?? "Controller") reconnecting…"
            // Immediately re-arm CoreBluetooth hardware reconnect + burst scan
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.activeEnabled, let p = self.peripherals[id] else { return }
                    if p.state != .connected && p.state != .connecting {
                        let side = self.pods[id]?.side ?? .unknown
                        let name = self.pods[id]?.name ?? side.displayName
                        self.connectPeripheral(p, side: side, displayName: name)
                    }
                    self.runScanBurstIfNeeded()
                }
            }
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            self.sessions[id]?.handshakeSent = false
            peripheral.discoverServices(nil)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            if error != nil {
                self.recyclePeripheral(id: peripheral.identifier, reason: "RSSI read failed")
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let services = peripheral.services, !services.isEmpty else { return }
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let chars = service.characteristics else { return }
            let id = peripheral.identifier
            for ch in chars {
                switch ch.uuid {
                case self.asyncUUID:
                    self.sessions[id]?.asyncChar = ch
                case self.syncRXUUID:
                    self.sessions[id]?.syncRXChar = ch
                case self.syncTXUUID:
                    self.sessions[id]?.syncTXChar = ch
                case self.batteryLevelUUID:
                    peripheral.readValue(for: ch)
                default:
                    break
                }
            }
            self.sendActivationIfReady(for: id, peripheral: peripheral)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let data = characteristic.value, !data.isEmpty else { return }
            let id = peripheral.identifier
            let uuid = characteristic.uuid

            if uuid == self.batteryLevelUUID {
                self.pods[id]?.battery = Int(data[0])
                return
            }

            if uuid == self.asyncUUID || uuid == self.syncTXUUID {
                self.touchInboundActivity(for: id, peripheral: peripheral)
            }

            if uuid == self.asyncUUID {
                if data.count >= 2 && data[0] == 0xFF && data[1] == 0x03 {
                    if let syncRX = self.sessions[id]?.syncRXChar {
                        self.handleChallenge(data, peripheral: peripheral, syncRX: syncRX)
                    }
                } else {
                    self.pods[id]?.isReady = true
                    self.pods[id]?.isReconnecting = false
                    self.handleAsyncFrame(data, for: id)
                }
            } else if uuid == self.syncTXUUID {
                if data.starts(with: ZwiftProtocol.rideOn) {
                    self.pods[id]?.isReady = true
                    self.pods[id]?.isReconnecting = false
                    if self.sessions[id]?.rideOnEchoed == false {
                        self.sessions[id]?.rideOnEchoed = true
                        self.lastEvent = "\(self.pods[id]?.side.displayName ?? "Controller") ready!"
                        if !self.isSignedInToZwift, let syncRX = self.sessions[id]?.syncRXChar {
                            self.writeSyncRX(ZwiftProtocol.emptyAck, to: peripheral, char: syncRX)
                            self.sessions[id]?.lastAckAt = Date()
                        }
                    }
                } else if data.count >= 2 && data[0] == 0xFF && data[1] == 0x03 {
                    if let syncRX = self.sessions[id]?.syncRXChar {
                        self.handleChallenge(data, peripheral: peripheral, syncRX: syncRX)
                    }
                }
            }
        }
    }
}
