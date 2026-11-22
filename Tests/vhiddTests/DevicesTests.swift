import Foundation
import Helper
import Keystrokes
import Pointing
import Synchronization
import TestClock
import Testing
import Timeline
@testable import vhidd

/// The devices as vhidd serves them, over recording devices of the test's own: what
/// the wire may carry that the device cannot, and what a client leaving lets go of.
@Suite struct DevicesTests {
    /// Holds keys the way the device does: noted before the request, which may throw
    /// having reached the driver, and cleared only by a release that succeeds.
    final class RecordingKeyboard: HeldKeyboard {
        private let recorded = Mutex<[String]>([])
        private let held = Mutex<Set<Usage>>([])
        let refusesRelease: Bool
        let refusesDown: Bool

        init(refusesRelease: Bool = false, refusesDown: Bool = false) {
            self.refusesRelease = refusesRelease
            self.refusesDown = refusesDown
        }

        var log: [String] { recorded.withLock { $0 } }
        var keysDown: Set<Usage> { held.withLock { $0 } }

        func down(_ usage: Usage, by deadline: Deadline) throws {
            recorded.withLock { $0.append("down \(usage.rawValue)") }
            held.withLock { _ = $0.insert(usage) }
            if refusesDown { throw Refused() }
        }
        func releaseAll(by deadline: Deadline) throws {
            recorded.withLock { $0.append("up") }
            if refusesRelease { throw Refused() }
            held.withLock { $0 = [] }
        }
        func hold(_ keys: HeldKeys, by deadline: Deadline) throws {
            recorded.withLock { $0.append("hold \(keys.usages.map(\.rawValue).sorted())") }
            held.withLock { $0 = keys.usages }
        }
    }

    final class RecordingMouse: HeldPointing {
        private let recorded = Mutex<[String]>([])

        var log: [String] { recorded.withLock { $0 } }

        func down(_ button: Button, by deadline: Deadline) throws { recorded.withLock { $0.append("down \(button.rawValue)") } }
        func releaseAll(by deadline: Deadline) throws { recorded.withLock { $0.append("up") } }
        func hold(_ buttons: Set<Button>, by deadline: Deadline) throws { recorded.withLock { $0.append("hold \(buttons.map(\.rawValue).sorted())") } }
        func move(_ delta: Move, by deadline: Deadline) throws { recorded.withLock { $0.append("move \(delta.x.value) \(delta.y.value)") } }
        func scroll(_ delta: Scroll, by deadline: Deadline) throws { recorded.withLock { $0.append("scroll \(delta.vertical.value) \(delta.horizontal.value)") } }
    }

    struct Refused: Error {}

    /// The act's answer, as a seat hands it to the client: nil, or the refusal.
    private func answer(_ act: () throws -> Void) -> Error? {
        do {
            try act()
            return nil
        } catch {
            return refusal(error)
        }
    }

    /// A button the device has no bit for, or a count the descriptor does not admit, is
    /// refused by name and never reaches the device. [LAW:parse-dont-validate]
    @Test func valuesTheDeviceCannotCarryAreRefusedBeforeItSeesThem() {
        let mouse = RecordingMouse()
        let devices = Devices(keyboard: RecordingKeyboard(), mouse: mouse, timeline: .suspending)
        #expect(answer { try devices.buttonDown(0, by: guarded()) }?.localizedDescription == "button 0 is not one of the 32 the device has a bit for")
        #expect(answer { try devices.buttonDown(33, by: guarded()) }?.localizedDescription == "button 33 is not one of the 32 the device has a bit for")
        #expect(answer { try devices.move(x: -128, y: 0, by: guarded()) }?.localizedDescription == "-128 is outside the -127 through 127 a report carries")
        #expect(answer { try devices.scroll(vertical: 1, horizontal: -128, by: guarded()) }?.localizedDescription == "-128 is outside the -127 through 127 a report carries")
        #expect(mouse.log.isEmpty)
        let keyboard = RecordingKeyboard()
        let typing = Devices(keyboard: keyboard, mouse: RecordingMouse(), timeline: .suspending)
        #expect(answer { try typing.down(usage: 3, by: guarded()) }?.localizedDescription == "usage 3 is not one of the keys 4 through 231")
        #expect(answer { try typing.hold(usages: [0xE1, 0xE8], by: guarded()) }?.localizedDescription == "usage 232 is not one of the keys 4 through 231")
        #expect(keyboard.log.isEmpty)
    }

    /// What the device can carry reaches it as asked, and the reply is nil.
    @Test func valuesTheDeviceCanCarryReachIt() {
        let keyboard = RecordingKeyboard()
        let mouse = RecordingMouse()
        let devices = Devices(keyboard: keyboard, mouse: mouse, timeline: .suspending)
        #expect(answer { try devices.down(usage: 0x04, by: guarded()) } == nil)
        #expect(answer { try devices.buttonDown(3, by: guarded()) } == nil)
        #expect(answer { try devices.move(x: 127, y: -127, by: guarded()) } == nil)
        #expect(answer { try devices.scroll(vertical: 1, horizontal: -1, by: guarded()) } == nil)
        #expect(answer { try devices.releaseButtons(by: guarded()) } == nil)
        #expect(answer { try devices.releaseAll(by: guarded()) } == nil)
        #expect(keyboard.log == ["down 4", "up"])
        #expect(mouse.log == ["down 3", "move 127 -127", "scroll 1 -1", "up"])
    }

    /// A refusal crosses as the one error a client can decode, carrying the words.
    @Test func aRefusalCrossesAsAnNSErrorCarryingItsDescription() throws {
        let devices = Devices(keyboard: RecordingKeyboard(), mouse: RecordingMouse(), timeline: .suspending)
        let error = try #require(answer { try devices.buttonDown(0, by: guarded()) }) as NSError
        #expect(error.domain == "ai.promptctl.vhid.vhidd.refusal")
        #expect(error.localizedDescription == "button 0 is not one of the 32 the device has a bit for")
    }

    /// A client leaving has both devices released, the mouse whatever the keyboard said.
    @Test func releasingEverythingReleasesBothDevicesWhateverTheKeyboardAnswers() {
        let keyboard = RecordingKeyboard(refusesRelease: true)
        let mouse = RecordingMouse()
        Devices(keyboard: keyboard, mouse: mouse, timeline: .suspending).releaseEverything(because: "the client went away")
        #expect(keyboard.log == ["up"])
        #expect(mouse.log == ["up"])
    }

    private func timed(_ keyboard: RecordingKeyboard = RecordingKeyboard(), _ mouse: RecordingMouse = RecordingMouse()) -> (Devices, ManualClock) {
        let clock = ManualClock()
        return (Devices(keyboard: keyboard, mouse: mouse, limit: .seconds(2), timeline: Timeline(clock)), clock)
    }

    /// A key left down with no keyboard report after it is released once the limit passes,
    /// naming the usages, and not before.
    @Test func aKeyHeldPastTheLimitIsReleased() {
        let keyboard = RecordingKeyboard()
        let (devices, clock) = timed(keyboard)
        _ = answer { try devices.down(usage: 0xE3, by: guarded()) }
        _ = answer { try devices.down(usage: 0x04, by: guarded()) }
        clock.advance(by: .milliseconds(1999))
        #expect(devices.releaseKeysHeldPastLimit { nil } == nil)
        clock.advance(by: .milliseconds(1))
        #expect(devices.releaseKeysHeldPastLimit { nil } == KeysLetGo(usages: [0x04, 0xE3], limit: .seconds(2), holder: nil, failure: nil))
        #expect(keyboard.log == ["down 227", "down 4", "up"])
        clock.advance(by: .seconds(5))
        #expect(devices.releaseKeysHeldPastLimit { nil } == nil)
    }

    /// Chords one after another, each well inside the limit, are never cut, however long
    /// the stream runs; nothing down means nothing to release.
    @Test func aSteadyStreamOfChordsIsNeverInterrupted() {
        let keyboard = RecordingKeyboard()
        let (devices, clock) = timed(keyboard)
        for _ in 0..<20 {
            _ = answer { try devices.down(usage: 0xE1, by: guarded()) }
            clock.advance(by: .milliseconds(900))
            #expect(devices.releaseKeysHeldPastLimit { nil } == nil)
            _ = answer { try devices.down(usage: 0x05, by: guarded()) }
            clock.advance(by: .milliseconds(900))
            #expect(devices.releaseKeysHeldPastLimit { nil } == nil)
            _ = answer { try devices.releaseAll(by: guarded()) }
            clock.advance(by: .seconds(10))
            #expect(devices.releaseKeysHeldPastLimit { nil } == nil)
        }
        #expect(keyboard.log.count == 60)
    }

    /// A button held past the limit stays down: a replayed pointer script holds one across gaps.
    @Test func aButtonHeldPastTheLimitIsNotReleased() {
        let mouse = RecordingMouse()
        let (devices, clock) = timed(RecordingKeyboard(), mouse)
        _ = answer { try devices.buttonDown(1, by: guarded()) }
        clock.advance(by: .seconds(30))
        #expect(devices.releaseKeysHeldPastLimit { nil } == nil)
        #expect(mouse.log == ["down 1"])
    }

    /// A release the keyboard refused is reported and tried again one limit later.
    @Test func aRefusedReleaseIsReportedAndRetriedAfterTheLimit() {
        let (devices, clock) = timed(RecordingKeyboard(refusesRelease: true))
        _ = answer { try devices.down(usage: 0x04, by: guarded()) }
        clock.advance(by: .seconds(2))
        #expect(devices.releaseKeysHeldPastLimit { nil }?.failure != nil)
        clock.advance(by: .milliseconds(250))
        #expect(devices.releaseKeysHeldPastLimit { nil } == nil)
        clock.advance(by: .milliseconds(1750))
        #expect(devices.releaseKeysHeldPastLimit { nil }?.usages == [0x04])
    }

    /// A key whose request threw after reaching the driver is still down on the device,
    /// and the deadline releases it.
    @Test func aKeyWhoseRequestThrewIsStillReleased() {
        let (devices, clock) = timed(RecordingKeyboard(refusesDown: true))
        #expect(answer { try devices.down(usage: 0x04, by: guarded()) } != nil)
        clock.advance(by: .seconds(2))
        #expect(devices.releaseKeysHeldPastLimit { nil }?.usages == [0x04])
    }

    /// A modifier held through a drag the client paces over seconds is live: every pointer
    /// report counts, and the modifier stays down.
    @Test func aModifierHeldThroughAPacedDragIsNotCut() {
        let (devices, clock) = timed()
        _ = answer { try devices.down(usage: 0xE2, by: guarded()) }
        _ = answer { try devices.buttonDown(1, by: guarded()) }
        for _ in 0..<30 {
            clock.advance(by: .milliseconds(200))
            _ = answer { try devices.move(x: 5, y: 0, by: guarded()) }
            #expect(devices.releaseKeysHeldPastLimit { nil } == nil)
        }
    }

    /// The deadline releases the keys and leaves the devices with the client that held them,
    /// and the log names that client and the keys.
    @Test func theHolderStillBelongsToTheClientAfterwards() throws {
        let (devices, clock) = timed()
        let readiness = Readiness.serving(devices)
        let holder = Holder()
        // Kept alive, so the two identifiers cannot share a freed address.
        let (first, second) = (NSObject(), NSObject())
        let up = try readiness.devices()
        try holder.claim(ObjectIdentifier(first), by: 4242, on: up)
        try devices.down(usage: 0x04, by: guarded())
        clock.advance(by: .seconds(3))
        #expect(releaseKeysHeldPastLimit(readiness, holder) == "pid 4242 held 0x04 past 2.0 seconds with no report; released")
        #expect(holder.pid(on: up.attempt) == 4242)
        #expect(throws: Holder.Busy.self) { try holder.claim(ObjectIdentifier(second), by: 1, on: up) }
        withExtendedLifetime((first, second)) {}
    }

    /// A held set crosses as the wire's usages, and a button set as its bit field, bit 0
    /// for button 1.
    @Test func heldSetsReachTheDevicesAsSets() {
        let keyboard = RecordingKeyboard()
        let mouse = RecordingMouse()
        let devices = Devices(keyboard: keyboard, mouse: mouse, timeline: .suspending)
        #expect(answer { try devices.hold(usages: [0xE1, 0x04, 0x04], by: guarded()) } == nil)
        #expect(answer { try devices.hold(usages: [], by: guarded()) } == nil)
        #expect(answer { try devices.holdButtons(0b101, by: guarded()) } == nil)
        #expect(answer { try devices.holdButtons(1 << 31, by: guarded()) } == nil)
        #expect(keyboard.log == ["hold [4, 225]", "hold []"])
        #expect(mouse.log == ["hold [1, 3]", "hold [32]"])
    }

    /// More keys than one report carries is refused by name, and the device never sees it.
    @Test func aSetNoReportCarriesIsRefusedByName() {
        let keyboard = RecordingKeyboard()
        let devices = Devices(keyboard: keyboard, mouse: RecordingMouse(), timeline: .suspending)
        let refusal = answer { try devices.hold(usages: Array(0x04...0x24), by: guarded()) }
        #expect(refusal?.localizedDescription == "33 keys are down, and one HID keyboard report carries 32")
        #expect(keyboard.log.isEmpty)
    }

    /// Repeating a held set is a report, so it keeps its keys past the limit; a player that
    /// stops repeating loses them.
    @Test func aRepeatedHoldKeepsItsKeysPastTheLimit() {
        let keyboard = RecordingKeyboard()
        let (devices, clock) = timed(keyboard)
        for _ in 0..<5 {
            _ = answer { try devices.hold(usages: [0xE1], by: guarded()) }
            clock.advance(by: .seconds(1))
            #expect(devices.releaseKeysHeldPastLimit { nil } == nil)
        }
        clock.advance(by: .seconds(1))
        #expect(devices.releaseKeysHeldPastLimit { nil }?.usages == [0xE1])
    }

    /// A client that leaves mid-hold has its keys and buttons released, however they came
    /// to be held.
    @Test func aClientLeavingMidHoldIsReleased() {
        let keyboard = RecordingKeyboard()
        let mouse = RecordingMouse()
        let client = NSObject()
        let seat = Seat(ObjectIdentifier(client), pid: 41, holder: Holder(), readiness: .serving(Devices(keyboard: keyboard, mouse: mouse, timeline: .suspending)), screen: FixedScreen(), timeline: .suspending)
        seat.hold(usages: [0xE1, 0x04]) { #expect($0 == nil) }
        seat.holdButtons(1) { #expect($0 == nil) }
        seat.end(because: "a client went away")
        #expect(keyboard.log == ["hold [4, 225]", "up"])
        #expect(keyboard.keysDown.isEmpty)
        #expect(mouse.log == ["hold [1]", "up"])
        withExtendedLifetime(client) {}
    }
}
