import Foundation
import Testing
@testable import ZwiftBoardCore

@Test func manufacturerDataParsing() {
    let leftData = Data([0x4A, 0x09, 0x0B, 0x12, 0x34])
    #expect(ZwiftProtocol.deviceID(fromManufacturerData: leftData) == 0x0B)
    #expect(ZwiftProtocol.PodSide(deviceID: 0x0B) == .left)

    let rightData = Data([0x4A, 0x09, 0x0A, 0x56, 0x78])
    #expect(ZwiftProtocol.PodSide(deviceID: 0x0A) == .right)

    let otherVendor = Data([0x4C, 0x00, 0x0B])
    #expect(ZwiftProtocol.deviceID(fromManufacturerData: otherVendor) == nil)
}

@Test func buttonBitmapDecoding() {
    let allReleased = Data([0x23, 0x08, 0xFF, 0x3F])
    #expect(ZwiftProtocol.pressedButtons(fromAsyncFrame: allReleased) == [])

    let plusPressed = Data([0x23, 0x08, 0xFF, 0x1F])
    #expect(ZwiftProtocol.pressedButtons(fromAsyncFrame: plusPressed) == [.plus])

    let minLeftPressed = Data([0x23, 0x08, 0xFE, 0x3D])
    #expect(ZwiftProtocol.pressedButtons(fromAsyncFrame: minLeftPressed) == [.min, .left])
}

@Test func safeMyWhooshKeymap() {
    // Default Shifting Only never maps arrows or Enter, and PLUS/Y = K, MIN/B = I
    #expect(MyWhooshKeymap.key(for: .plus, preset: .shiftingOnly, swapShift: false) == .k)
    #expect(MyWhooshKeymap.key(for: .y, preset: .shiftingOnly, swapShift: false) == .k)
    #expect(MyWhooshKeymap.key(for: .min, preset: .shiftingOnly, swapShift: false) == .i)
    #expect(MyWhooshKeymap.key(for: .b, preset: .shiftingOnly, swapShift: false) == .i)
    #expect(MyWhooshKeymap.key(for: .a, preset: .shiftingOnly, swapShift: false) == nil)
    #expect(MyWhooshKeymap.key(for: .left, preset: .shiftingOnly, swapShift: false) == nil)

    // Shifting + Steering keeps consistent PLUS = K, MIN/B = I, plus steering & HUD
    #expect(MyWhooshKeymap.key(for: .plus, preset: .shiftingAndSteering, swapShift: false) == .k)
    #expect(MyWhooshKeymap.key(for: .b, preset: .shiftingAndSteering, swapShift: false) == .i)
    #expect(MyWhooshKeymap.key(for: .a, preset: .shiftingAndSteering, swapShift: false) == .right)
    #expect(MyWhooshKeymap.key(for: .z, preset: .shiftingAndSteering, swapShift: false) == .left)
    #expect(MyWhooshKeymap.key(for: .y, preset: .shiftingAndSteering, swapShift: false) == .u)
}

@Test func holdTrackerDeduplicatesAndGlobalReleases() {
    let tracker = HoldTracker()
    let leftSession = UUID()
    let rightSession = UUID()

    #expect(tracker.press(key: .k, sessionID: leftSession) == true)
    #expect(tracker.press(key: .k, sessionID: rightSession) == false)

    #expect(tracker.release(key: .k, sessionID: leftSession) == false)
    #expect(tracker.release(key: .k, sessionID: rightSession) == true)

    #expect(tracker.press(key: .i, sessionID: leftSession) == true)
    #expect(tracker.releaseAllGlobal() == [.i])
}

@Test func challengePayloadExtraction() {
    let frame = Data([0xFF, 0x03, 0x00, 0xAA, 0xBB, 0xCC])
    #expect(ZwiftProtocol.challengePayload(fromFrame: frame) == Data([0xAA, 0xBB, 0xCC]))
    #expect(ZwiftProtocol.challengePayload(fromFrame: Data([0xFF, 0x03, 0x00])) == nil)
}
