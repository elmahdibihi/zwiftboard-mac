@preconcurrency import CoreBluetooth
import Foundation

@MainActor
public final class BLEManager: NSObject, ObservableObject {
    public struct PodStatus: Identifiable, Sendable {
        public let id: UUID
        public var name: String
        public var side: ZwiftProtocol.PodSide
        public var battery: Int?
        public var isReady: Bool
        public var isLockedWarning: Bool
    }

    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var pods: [UUID: PodStatus] = [:]
    @Published public private(set) var lastEvent: String = "Waiting for Zwift Click…"
    @Published public private(set) var isSignedInToZwift: Bool = false

    @Published public var mode: ControllerMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "ZwiftBoard.Mode") }
    }
    @Published public var swapShiftKeys: Bool {
        didSet { UserDefaults.standard.set(swapShiftKeys, forKey: "ZwiftBoard.SwapShift") }
    }
    @Published public var autoFocusMyWhoosh: Bool {
        didSet { UserDefaults.standard.set(autoFocusMyWhoosh, forKey: "ZwiftBoard.AutoFocus") }
    }

    public let unlockClient = ZwiftUnlockClient()
    private let holdTracker = HoldTracker()

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var sessions: [UUID: PodSession] = [:]

    private let zwiftServiceUUID = CBUUID(string: ZwiftProtocol.serviceUUIDString)
    private let legacyZwiftServiceUUID = CBUUID(string: ZwiftProtocol.legacyServiceUUIDString)
    private let asyncUUID = CBUUID(string: ZwiftProtocol.asyncUUIDString)
    private let syncRXUUID = CBUUID(string: ZwiftProtocol.syncRXUUIDString)
    private let syncTXUUID = CBUUID(string: ZwiftProtocol.syncTXUUIDString)
    private let batteryServiceUUID = CBUUID(string: ZwiftProtocol.batteryServiceUUIDString)
    private let batteryLevelUUID = CBUUID(string: ZwiftProtocol.batteryLevelUUIDString)

    private struct PodSession {
        let sessionID = UUID()
        var side: ZwiftProtocol.PodSide
        var asyncChar: CBCharacteristic?
        var syncRXChar: CBCharacteristic?
        var syncTXChar: CBCharacteristic?
        var pressedButtons: Set<ZwiftProtocol.Button> = []
        var handshakeSent = false
        var lastButtonAt = Date()
        var resetSent = false
        var keepaliveTimer: Timer?
    }

    private func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/zwiftboard.log")
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    public override init() {
        let savedMode = UserDefaults.standard.string(forKey: "ZwiftBoard.Mode")
        self.mode = ControllerMode(rawValue: savedMode ?? "") ?? .double
        self.swapShiftKeys = UserDefaults.standard.bool(forKey: "ZwiftBoard.SwapShift")
        if UserDefaults.standard.object(forKey: "ZwiftBoard.AutoFocus") == nil {
            self.autoFocusMyWhoosh = true
        } else {
            self.autoFocusMyWhoosh = UserDefaults.standard.bool(forKey: "ZwiftBoard.AutoFocus")
        }
        super.init()
        log("INIT axTrusted=\(KeySender.isAccessibilityTrusted(prompt: false)) mode=\(mode.rawValue)")
        self.central = CBCentralManager(delegate: self, queue: .main)
        Task {
            self.isSignedInToZwift = await unlockClient.isSignedIn
        }
    }

    public func startScanning() {
        guard central.state == .poweredOn else { return }
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    public func stopScanning() {
        isScanning = false
        central.stopScan()
    }

    public func reconnectAll() {
        for (_, p) in peripherals {
            central.cancelPeripheralConnection(p)
        }
        peripherals.removeAll()
        sessions.removeAll()
        pods.removeAll()
        startScanning()
    }

    public func signInToZwift(email: String, password: String) async throws {
        try await unlockClient.login(email: email, password: password)
        isSignedInToZwift = true
        // Reconnect left pod if connected so it re-challenges and gets signed unlock
        for (id, session) in sessions where session.side == .left {
            if let p = peripherals[id] {
                central.cancelPeripheralConnection(p)
            }
        }
    }

    public func signOutOfZwift() async {
        await unlockClient.signOut()
        isSignedInToZwift = false
    }

    private func writeSyncRX(_ data: Data, to peripheral: CBPeripheral, char: CBCharacteristic) {
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: char, type: writeType)
    }

    private func sendActivationIfReady(for id: UUID, peripheral: CBPeripheral) {
        guard var session = sessions[id],
              !session.handshakeSent,
              let asyncChar = session.asyncChar,
              let syncRX = session.syncRXChar,
              let syncTX = session.syncTXChar else { return }

        session.handshakeSent = true
        session.lastButtonAt = Date()
        session.resetSent = false

        peripheral.setNotifyValue(true, for: asyncChar)
        peripheral.setNotifyValue(true, for: syncTX)

        for (idx, frame) in ZwiftProtocol.activationFrames.enumerated() {
            let delay = Double(idx) * 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
                guard let self, let peripheral, self.sessions[id] != nil else { return }
                self.writeSyncRX(frame, to: peripheral, char: syncRX)
            }
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let peripheral = self.peripherals[id], var s = self.sessions[id], let rx = s.syncRXChar else { return }
                let idle = Date().timeIntervalSince(s.lastButtonAt)
                if idle >= 55.0 && !s.resetSent {
                    s.resetSent = true
                    self.sessions[id] = s
                    self.writeSyncRX(ZwiftProtocol.resetPod, to: peripheral, char: rx)
                } else {
                    self.writeSyncRX(ZwiftProtocol.rideOn, to: peripheral, char: rx)
                }
            }
        }
        session.keepaliveTimer = timer
        sessions[id] = session
    }

    private func handleChallenge(_ frame: Data, peripheral: CBPeripheral, syncRX: CBCharacteristic) {
        guard let payload = ZwiftProtocol.challengePayload(fromSyncTXFrame: frame) else {
            writeSyncRX(ZwiftProtocol.emptyAck, to: peripheral, char: syncRX)
            return
        }
        let id = peripheral.identifier
        let side = self.pods[id]?.side
        Task {
            let signed = await unlockClient.isSignedIn
            if !signed {
                await MainActor.run {
                    self.writeSyncRX(ZwiftProtocol.emptyAck, to: peripheral, char: syncRX)
                    if side == .left, var status = self.pods[id] {
                        status.isLockedWarning = true
                        self.pods[id] = status
                    }
                }
                return
            }
            do {
                let reply = try await unlockClient.solve(challenge: payload)
                let responseFrame = ZwiftProtocol.emptyAck + reply
                await MainActor.run {
                    self.writeSyncRX(responseFrame, to: peripheral, char: syncRX)
                    if var status = self.pods[id] {
                        status.isLockedWarning = false
                        status.isReady = true
                        self.pods[id] = status
                    }
                }
            } catch {
                await MainActor.run {
                    self.writeSyncRX(ZwiftProtocol.emptyAck, to: peripheral, char: syncRX)
                    self.lastEvent = "Unlock failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleAsyncFrame(_ data: Data, for id: UUID) {
        guard let nextButtons = ZwiftProtocol.pressedButtons(fromAsyncFrame: data),
              var session = sessions[id] else { return }

        session.lastButtonAt = Date()
        session.resetSent = false
        let prevButtons = session.pressedButtons
        session.pressedButtons = nextButtons
        sessions[id] = session

        let newlyPressed = nextButtons.subtracting(prevButtons)
        let newlyReleased = prevButtons.subtracting(nextButtons)

        for btn in newlyPressed {
            if let key = MyWhooshKeymap.key(for: btn, mode: mode, swapShift: swapShiftKeys) {
                if holdTracker.press(key: key, sessionID: session.sessionID) {
                    KeySender.send(key: key, down: true, autoFocusMyWhoosh: autoFocusMyWhoosh)
                    lastEvent = "\(btn.rawValue) → \(key.rawValue.uppercased())"
                    log("PRESS \(btn.rawValue) -> \(key.rawValue) ax=\(KeySender.isAccessibilityTrusted(prompt: false))")
                }
            } else {
                lastEvent = "\(btn.rawValue) (unmapped in \(mode == .single ? "Single" : "Double"))"
                log("PRESS_UNMAPPED \(btn.rawValue) mode=\(mode.rawValue)")
            }
        }

        for btn in newlyReleased {
            if let key = MyWhooshKeymap.key(for: btn, mode: mode, swapShift: swapShiftKeys) {
                if holdTracker.release(key: key, sessionID: session.sessionID) {
                    KeySender.send(key: key, down: false, autoFocusMyWhoosh: false)
                }
            }
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            let state = central.state
            self.bluetoothState = state
            if state == .poweredOn {
                self.startScanning()
            } else {
                self.isScanning = false
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
            let id = peripheral.identifier
            guard self.peripherals[id] == nil else { return }
            self.peripherals[id] = peripheral
            peripheral.delegate = self
            self.sessions[id] = PodSession(side: side)
            self.pods[id] = PodStatus(
                id: id,
                name: localName.isEmpty ? side.displayName : localName,
                side: side,
                battery: nil,
                isReady: false,
                isLockedWarning: false
            )
            self.lastEvent = "Connecting to \(side.displayName)…"
            self.central.connect(peripheral, options: nil)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([self.zwiftServiceUUID, self.legacyZwiftServiceUUID, self.batteryServiceUUID])
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            self.peripherals.removeValue(forKey: id)
            self.sessions.removeValue(forKey: id)
            self.pods.removeValue(forKey: id)
            self.startScanning()
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            if let session = self.sessions.removeValue(forKey: id) {
                session.keepaliveTimer?.invalidate()
                let lifted = self.holdTracker.releaseAll(sessionID: session.sessionID)
                for key in lifted {
                    KeySender.send(key: key, down: false, autoFocusMyWhoosh: false)
                }
            }
            self.peripherals.removeValue(forKey: id)
            self.pods.removeValue(forKey: id)
            self.startScanning()
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let services = peripheral.services else { return }
            for service in services {
                if service.uuid == self.zwiftServiceUUID || service.uuid == self.legacyZwiftServiceUUID {
                    peripheral.discoverCharacteristics([self.asyncUUID, self.syncRXUUID, self.syncTXUUID], for: service)
                } else if service.uuid == self.batteryServiceUUID {
                    peripheral.discoverCharacteristics([self.batteryLevelUUID], for: service)
                }
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
            } else if uuid == self.asyncUUID {
                if data.count >= 2 && data[0] == 0xFF && data[1] == 0x03 {
                    if let syncRX = self.sessions[id]?.syncRXChar {
                        self.handleChallenge(data, peripheral: peripheral, syncRX: syncRX)
                    }
                } else {
                    self.pods[id]?.isReady = true
                    self.handleAsyncFrame(data, for: id)
                }
            } else if uuid == self.syncTXUUID {
                if data.starts(with: ZwiftProtocol.rideOn) {
                    self.pods[id]?.isReady = true
                    self.pods[id]?.isLockedWarning = false
                    self.lastEvent = "\(self.pods[id]?.side.displayName ?? "Controller") ready!"
                } else if data.count >= 2 && data[0] == 0xFF && data[1] == 0x03 {
                    if let syncRX = self.sessions[id]?.syncRXChar {
                        self.handleChallenge(data, peripheral: peripheral, syncRX: syncRX)
                    }
                }
            }
        }
    }
}
