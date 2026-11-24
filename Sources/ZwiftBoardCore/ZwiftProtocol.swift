import Foundation

public enum ZwiftProtocol {
    public static let companyID: UInt16 = 0x094A

    public static let serviceUUIDString = "FC82"
    public static let legacyServiceUUIDString = "00000001-19ca-4651-86e5-fa29dcdd09d1"
    public static let asyncUUIDString = "00000002-19ca-4651-86e5-fa29dcdd09d1"
    public static let syncRXUUIDString = "00000003-19ca-4651-86e5-fa29dcdd09d1"
    public static let syncTXUUIDString = "00000004-19ca-4651-86e5-fa29dcdd09d1"

    public static let batteryServiceUUIDString = "180F"
    public static let batteryLevelUUIDString = "2A19"

    public static let msgKeyPad: UInt8 = 0x23

    public static let rideOn = Data("RideOn".utf8)
    public static let handshakeStart = rideOn + Data([0x02, 0x03])
    public static let activationFrames: [Data] = [
        handshakeStart,
        Data([0x00, 0x08, 0x00]),
        Data([0x00, 0x08, 0x10])
    ]
    public static let emptyAck = Data([0xFF, 0x04, 0x00])
    public static let resetPod = Data([0x18])

    public static let podClickV1DeviceID: UInt8 = 0x09
    public static let podRightDeviceID: UInt8 = 0x0A
    public static let podLeftDeviceID: UInt8 = 0x0B

    public enum PodSide: String, Sendable, Hashable {
        case left
        case right
        case clickV1
        case unknown

        public init(deviceID: UInt8) {
            switch deviceID {
            case ZwiftProtocol.podLeftDeviceID: self = .left
            case ZwiftProtocol.podRightDeviceID: self = .right
            case ZwiftProtocol.podClickV1DeviceID: self = .clickV1
            default: self = .unknown
            }
        }

        public var displayName: String {
            switch self {
            case .left: return "Left Pod"
            case .right: return "Right Pod"
            case .clickV1: return "Zwift Click"
            case .unknown: return "Zwift Controller"
            }
        }
    }

    public enum Button: String, CaseIterable, Sendable, Hashable {
        case left = "LEFT"
        case up = "UP"
        case right = "RIGHT"
        case down = "DOWN"
        case a = "A"
        case b = "B"
        case y = "Y"
        case z = "Z"
        case min = "MIN"
        case plus = "PLUS"

        public var bitMask: UInt32 {
            switch self {
            case .left:  return 0x00001
            case .up:    return 0x00002
            case .right: return 0x00004
            case .down:  return 0x00008
            case .a:     return 0x00010
            case .b:     return 0x00020
            case .y:     return 0x00040
            case .z:     return 0x00080
            case .min:   return 0x00100
            case .plus:  return 0x01000
            }
        }
    }

    /// Extracts Zwift device ID from BLE manufacturer data (company 0x094A, little-endian).
    public static func deviceID(fromManufacturerData data: Data) -> UInt8? {
        guard data.count >= 3 else { return nil }
        let cid = UInt16(data[0]) | (UInt16(data[1]) << 8)
        guard cid == companyID else { return nil }
        return data[2]
    }

    /// Decodes a protobuf varint starting at `offset`, returning (value, bytesRead).
    public static func decodeUvarint(_ data: Data, offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset
        while i < data.count && (i - offset) < 10 {
            let byte = data[i]
            result |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte < 0x80 {
                return (result, i - offset)
            }
            shift += 7
        }
        return nil
    }

    /// Extracts field 1 (varint) button bitmap from a 0x23 frame payload (after the 0x23 byte).
    /// Bit == 0 means the button is pressed.
    public static func decodeBitmap(payload: Data) -> UInt32? {
        var i = 0
        while i < payload.count {
            guard let (tag, tagLen) = decodeUvarint(payload, offset: i) else { return nil }
            i += tagLen
            let fieldNum = tag >> 3
            let wireType = tag & 7
            switch wireType {
            case 0: // varint
                guard let (val, valLen) = decodeUvarint(payload, offset: i) else { return nil }
                i += valLen
                if fieldNum == 1 {
                    return UInt32(truncatingIfNeeded: val)
                }
            case 1: // 64-bit
                i += 8
            case 2: // length-delimited
                guard let (len, lenBytes) = decodeUvarint(payload, offset: i) else { return nil }
                i += lenBytes + Int(len)
            case 5: // 32-bit
                i += 4
            default:
                return nil
            }
        }
        return nil
    }

    /// Returns the set of currently pressed buttons from a raw Async notification frame.
    /// Returns nil if the frame is not a 0x23 keypad frame or cannot be decoded.
    public static func pressedButtons(fromAsyncFrame frame: Data) -> Set<Button>? {
        guard frame.count >= 2, frame[0] == msgKeyPad else { return nil }
        let payload = frame.subdata(in: 1..<frame.count)
        guard let bitmap = decodeBitmap(payload: payload) else { return nil }
        var pressed = Set<Button>()
        for button in Button.allCases {
            if (bitmap & button.bitMask) == 0 {
                pressed.insert(button)
            }
        }
        return pressed
    }

    /// Extracts the protobuf challenge payload from a `FF 03 00 <payload>` frame.
    public static func challengePayload(fromFrame frame: Data) -> Data? {
        guard frame.count >= 4, frame[0] == 0xFF, frame[1] == 0x03 else { return nil }
        return frame.subdata(in: 3..<frame.count)
    }
}

public enum KeymapPreset: String, CaseIterable, Sendable {
    case shiftingOnly = "Shifting Only (Safe)"
    case shiftingAndSteering = "Shifting + Steering"
}

public enum KeyCode: String, Sendable, Hashable {
    case i, k, u, left, right

    public var displayLabel: String {
        switch self {
        case .i: return "I (Shift Down)"
        case .k: return "K (Shift Up)"
        case .u: return "U (HUD Toggle)"
        case .left: return "← (Steer Left)"
        case .right: return "→ (Steer Right)"
        }
    }
}

public struct MyWhooshKeymap: Sendable {
    /// Consistent, safe mapping for MyWhoosh:
    /// - Never maps Enter or Space (which randomly click focused HUD buttons / Pause in MyWhoosh).
    /// - Works seamlessly with 1 pod (Right Pod: PLUS/Y = Harder, B = Easier) OR both pods (PLUS = Harder, MIN = Easier).
    public static func key(for button: ZwiftProtocol.Button, preset: KeymapPreset, swapShift: Bool) -> KeyCode? {
        let shiftUp: KeyCode = swapShift ? .i : .k
        let shiftDown: KeyCode = swapShift ? .k : .i

        switch preset {
        case .shiftingOnly:
            switch button {
            case .plus, .y: return shiftUp
            case .min, .b:  return shiftDown
            default:        return nil
            }
        case .shiftingAndSteering:
            switch button {
            case .plus:       return shiftUp
            case .min, .b:    return shiftDown
            case .left, .z:   return .left
            case .right, .a:  return .right
            case .y:          return .u
            case .up, .down:  return nil
            }
        }
    }

    public static func summaryLines(preset: KeymapPreset, swapShift: Bool) -> [String] {
        let harderKey = swapShift ? "I" : "K"
        let easierKey = swapShift ? "K" : "I"
        switch preset {
        case .shiftingOnly:
            return [
                "Harder (\(harderKey)): + or Y",
                "Easier (\(easierKey)): − or B"
            ]
        case .shiftingAndSteering:
            return [
                "Harder (\(harderKey)): +   ·   Easier (\(easierKey)): − or B",
                "Steer (←/→): Arrows or Z/A   ·   HUD (U): Y"
            ]
        }
    }
}

/// Deduplicates mirrored button frames from Left + Right pods and ensures held keys
/// are cleanly released if a pod disconnects or keymap settings change mid-press.
public final class HoldTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var globalCounts: [KeyCode: Int] = [:]
    private var perSessionCounts: [UUID: [KeyCode: Int]] = [:]

    public init() {}

    /// Records a key press for `sessionID`. Returns `true` if this is the first
    /// active press of `key` across all pods (caller should emit keyDown).
    public func press(key: KeyCode, sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var sessionMap = perSessionCounts[sessionID, default: [:]]
        sessionMap[key, default: 0] += 1
        perSessionCounts[sessionID] = sessionMap

        let nextGlobal = globalCounts[key, default: 0] + 1
        globalCounts[key] = nextGlobal
        return nextGlobal == 1
    }

    /// Records a key release for `sessionID`. Returns `true` if no pod holds `key`
    /// anymore (caller should emit keyUp).
    public func release(key: KeyCode, sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var sessionMap = perSessionCounts[sessionID],
              let own = sessionMap[key], own > 0 else {
            return false
        }
        if own == 1 {
            sessionMap.removeValue(forKey: key)
        } else {
            sessionMap[key] = own - 1
        }
        perSessionCounts[sessionID] = sessionMap

        let currentGlobal = globalCounts[key, default: 0]
        if currentGlobal <= 1 {
            globalCounts.removeValue(forKey: key)
            return true
        } else {
            globalCounts[key] = currentGlobal - 1
            return false
        }
    }

    /// Releases all keys held by `sessionID` (e.g., on disconnect), returning the
    /// keys that reached 0 globally and must have keyUp emitted.
    public func releaseAll(sessionID: UUID) -> [KeyCode] {
        lock.lock()
        defer { lock.unlock() }
        guard let sessionMap = perSessionCounts.removeValue(forKey: sessionID) else {
            return []
        }
        var toLift: [KeyCode] = []
        for (key, count) in sessionMap {
            let current = globalCounts[key, default: 0]
            if current <= count {
                globalCounts.removeValue(forKey: key)
                toLift.append(key)
            } else {
                globalCounts[key] = current - count
            }
        }
        return toLift
    }

    /// Force-releases every held key across all sessions (e.g., when changing preset or shift swap).
    public func releaseAllGlobal() -> [KeyCode] {
        lock.lock()
        defer { lock.unlock() }
        let keys = Array(globalCounts.keys)
        globalCounts.removeAll()
        perSessionCounts.removeAll()
        return keys
    }
}
