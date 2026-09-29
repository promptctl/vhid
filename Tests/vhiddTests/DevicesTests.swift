import Foundation
import Helper
import Keystrokes
import Pointing
import Synchronization
import Testing
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

        func down(_ usage: Usage) throws {
            recorded.withLock { $0.append("down \(usage.rawValue)") }
            held.withLock { _ = $0.insert(usage) }
            if refusesDown { throw Refused() }
        }
        func releaseAll() throws {
            recorded.withLock { $0.append("up") }
            if refusesRelease { throw Refused() }
            held.withLock { $0 = [] }
        }
        func hold(_ keys: HeldKeys) throws {
            recorded.withLock { $0.append("hold \(keys.usages.map(\.rawValue).sorted())") }
            held.withLock { $0 = keys.usages }
        }
    }

    final class RecordingMouse: PointingDevice {
        private let recorded = Mutex<[String]>([])

        var log: [String] { recorded.withLock { $0 } }

        func down(_ button: Button) throws { recorded.withLock { $0.append("down \(button.rawValue)") } }
        func releaseAll() throws { recorded.withLock { $0.append("up") } }
        func hold(_ buttons: Set<Button>) throws { recorded.withLock { $0.append("hold \(buttons.map(\.rawValue).sorted())") } }
        func move(by delta: Move) throws { recorded.withLock { $0.append("move \(delta.x.value) \(delta.y.value)") } }
        func scroll(by delta: Scroll) throws { recorded.withLock { $0.append("scroll \(delta.vertical.value) \(delta.horizontal.value)") } }
    }

    struct Refused: Error {}

    /// The reply, as the client gets it: nil, or the refusal.
    private func answer(_ call: (@escaping (Error?) -> Void) -> Void) -> Error? {
        var answered: Error?
        call { answered = $0 }
        return answered
    }

    /// A button the device has no bit for, or a count the descriptor does not admit, is
    /// refused by name and never reaches the device. [LAW:parse-dont-validate]
    @Test func valuesTheDeviceCannotCarryAreRefusedBeforeItSeesThem() {
        let mouse = RecordingMouse()
        let devices = Devices(keyboard: RecordingKeyboard(), mouse: mouse)
        #expect(answer { devices.buttonDown(0, reply: $0) }?.localizedDescription == "button 0 is not one of the 32 the device has a bit for")
        #expect(answer { devices.buttonDown(33, reply: $0) }?.localizedDescription == "button 33 is not one of the 32 the device has a bit for")
        #expect(answer { devices.move(x: -128, y: 0, reply: $0) }?.localizedDescription == "-128 is outside the -127 through 127 a report carries")
        #expect(answer { devices.scroll(vertical: 1, horizontal: -128, reply: $0) }?.localizedDescription == "-128 is outside the -127 through 127 a report carries")
        #expect(mouse.log.isEmpty)
        let keyboard = RecordingKeyboard()
        let typing = Devices(keyboard: keyboard, mouse: RecordingMouse())
        #expect(answer { typing.down(usage: 3, reply: $0) }?.localizedDescription == "usage 3 is not one of the keys 4 through 231")
        #expect(answer { typing.hold(usages: [0xE1, 0xE8], reply: $0) }?.localizedDescription == "usage 232 is not one of the keys 4 through 231")
        #expect(keyboard.log.isEmpty)
    }

    /// What the device can carry reaches it as asked, and the reply is nil.
    @Test func valuesTheDeviceCanCarryReachIt() {
        let keyboard = RecordingKeyboard()
        let mouse = RecordingMouse()
        let devices = Devices(keyboard: keyboard, mouse: mouse)
        #expect(answer { devices.down(usage: 0x04, reply: $0) } == nil)
        #expect(answer { devices.buttonDown(3, reply: $0) } == nil)
        #expect(answer { devices.move(x: 127, y: -127, reply: $0) } == nil)
        #expect(answer { devices.scroll(vertical: 1, horizontal: -1, reply: $0) } == nil)
        #expect(answer { devices.releaseButtons(reply: $0) } == nil)
        #expect(answer { devices.releaseAll(reply: $0) } == nil)
        #expect(keyboard.log == ["down 4", "up"])
        #expect(mouse.log == ["down 3", "move 127 -127", "scroll 1 -1", "up"])
    }

    /// A refusal crosses as the one error a client can decode, carrying the words.
    @Test func aRefusalCrossesAsAnNSErrorCarryingItsDescription() throws {
        let devices = Devices(keyboard: RecordingKeyboard(), mouse: RecordingMouse())
        let error = try #require(answer { devices.buttonDown(0, reply: $0) }) as NSError
        #expect(error.domain == "ai.promptctl.vhid.vhidd.refusal")
        #expect(error.localizedDescription == "button 0 is not one of the 32 the device has a bit for")
    }

    /// A client leaving has both devices released, the mouse whatever the keyboard said.
    @Test func releasingEverythingReleasesBothDevicesWhateverTheKeyboardAnswers() {
        let keyboard = RecordingKeyboard(refusesRelease: true)
        let mouse = RecordingMouse()
        Devices(keyboard: keyboard, mouse: mouse).releaseEverything(because: "the client went away")
        #expect(keyboard.log == ["up"])
        #expect(mouse.log == ["up"])
    }

    /// A clock the test moves by hand.
    final class Clock: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(_ by: Duration) { instant.withLock { $0 += by } }
    }

    private func timed(_ keyboard: RecordingKeyboard = RecordingKeyboard(), _ mouse: RecordingMouse = RecordingMouse()) -> (Devices, Clock) {
        let clock = Clock()
        return (Devices(keyboard: keyboard, mouse: mouse, limit: .seconds(2), now: { clock.now }), clock)
    }

    /// A key left down with no keyboard report after it is released once the limit passes,
    /// naming the usages, and not before.
    @Test func aKeyHeldPastTheLimitIsReleased() {
        let keyboard = RecordingKeyboard()
        let (devices, clock) = timed(keyboard)
        _ = answer { devices.down(usage: 0xE3, reply: $0) }
        _ = answer { devices.down(usage: 0x04, reply: $0) }
        clock.advance(.milliseconds(1999))
        #expect(devices.releaseKeysHeldPastLimit() == nil)
        clock.advance(.milliseconds(1))
        #expect(devices.releaseKeysHeldPastLimit() == KeysLetGo(usages: [0x04, 0xE3], limit: .seconds(2), failure: nil))
        #expect(keyboard.log == ["down 227", "down 4", "up"])
        clock.advance(.seconds(5))
        #expect(devices.releaseKeysHeldPastLimit() == nil)
    }

    /// Chords one after another, each well inside the limit, are never cut, however long
    /// the stream runs; nothing down means nothing to release.
    @Test func aSteadyStreamOfChordsIsNeverInterrupted() {
        let keyboard = RecordingKeyboard()
        let (devices, clock) = timed(keyboard)
        for _ in 0..<20 {
            _ = answer { devices.down(usage: 0xE1, reply: $0) }
            clock.advance(.milliseconds(900))
            #expect(devices.releaseKeysHeldPastLimit() == nil)
            _ = answer { devices.down(usage: 0x05, reply: $0) }
            clock.advance(.milliseconds(900))
            #expect(devices.releaseKeysHeldPastLimit() == nil)
            _ = answer { devices.releaseAll(reply: $0) }
            clock.advance(.seconds(10))
            #expect(devices.releaseKeysHeldPastLimit() == nil)
        }
        #expect(keyboard.log.count == 60)
    }

    /// A button held past the limit stays down: a replayed pointer script holds one across gaps.
    @Test func aButtonHeldPastTheLimitIsNotReleased() {
        let mouse = RecordingMouse()
        let (devices, clock) = timed(RecordingKeyboard(), mouse)
        _ = answer { devices.buttonDown(1, reply: $0) }
        clock.advance(.seconds(30))
        #expect(devices.releaseKeysHeldPastLimit() == nil)
        #expect(mouse.log == ["down 1"])
    }

    /// A release the keyboard refused is reported and tried again one limit later.
    @Test func aRefusedReleaseIsReportedAndRetriedAfterTheLimit() {
        let (devices, clock) = timed(RecordingKeyboard(refusesRelease: true))
        _ = answer { devices.down(usage: 0x04, reply: $0) }
        clock.advance(.seconds(2))
        #expect(devices.releaseKeysHeldPastLimit()?.failure != nil)
        clock.advance(.milliseconds(250))
        #expect(devices.releaseKeysHeldPastLimit() == nil)
        clock.advance(.milliseconds(1750))
        #expect(devices.releaseKeysHeldPastLimit()?.usages == [0x04])
    }

    /// A key whose request threw after reaching the driver is still down on the device,
    /// and the deadline releases it.
    @Test func aKeyWhoseRequestThrewIsStillReleased() {
        let (devices, clock) = timed(RecordingKeyboard(refusesDown: true))
        #expect(answer { devices.down(usage: 0x04, reply: $0) } != nil)
        clock.advance(.seconds(2))
        #expect(devices.releaseKeysHeldPastLimit()?.usages == [0x04])
    }

    /// A modifier held through a drag the client paces over seconds is live: every pointer
    /// report counts, and the modifier stays down.
    @Test func aModifierHeldThroughAPacedDragIsNotCut() {
        let (devices, clock) = timed()
        _ = answer { devices.down(usage: 0xE2, reply: $0) }
        _ = answer { devices.buttonDown(1, reply: $0) }
        for _ in 0..<30 {
            clock.advance(.milliseconds(200))
            _ = answer { devices.move(x: 5, y: 0, reply: $0) }
            #expect(devices.releaseKeysHeldPastLimit() == nil)
        }
    }

    /// The deadline releases the keys and leaves the devices with the client that held them,
    /// and the log names that client and the keys.
    @Test func theHolderStillBelongsToTheClientAfterwards() throws {
        let (devices, clock) = timed()
        let readiness = Readiness.serving(devices)
        let holder = Holder()
        // Kept alive, so the two identifiers cannot share a freed address.
        let (first, second) = (Clock(), Clock())
        let client = ObjectIdentifier(first)
        let attempt = try readiness.devices().attempt
        try holder.serve(client, by: 4242, on: attempt) { devices.down(usage: 0x04) { _ in } }
        clock.advance(.seconds(3))
        #expect(releaseKeysHeldPastLimit(readiness, holder) == "pid 4242 held 0x04 past 2.0 seconds with no report; released")
        #expect(holder.pid(on: attempt) == 4242)
        #expect(throws: Holder.Busy.self) { try holder.serve(ObjectIdentifier(second), by: 1, on: attempt) {} }
        withExtendedLifetime((first, second)) {}
    }

    /// A held set crosses as the wire's usages, and a button set as its bit field, bit 0
    /// for button 1.
    @Test func heldSetsReachTheDevicesAsSets() {
        let keyboard = RecordingKeyboard()
        let mouse = RecordingMouse()
        let devices = Devices(keyboard: keyboard, mouse: mouse)
        #expect(answer { devices.hold(usages: [0xE1, 0x04, 0x04], reply: $0) } == nil)
        #expect(answer { devices.hold(usages: [], reply: $0) } == nil)
        #expect(answer { devices.holdButtons(0b101, reply: $0) } == nil)
        #expect(answer { devices.holdButtons(1 << 31, reply: $0) } == nil)
        #expect(keyboard.log == ["hold [4, 225]", "hold []"])
        #expect(mouse.log == ["hold [1, 3]", "hold [32]"])
    }

    /// More keys than one report carries is refused by name, and the device never sees it.
    @Test func aSetNoReportCarriesIsRefusedByName() {
        let keyboard = RecordingKeyboard()
        let devices = Devices(keyboard: keyboard, mouse: RecordingMouse())
        let refusal = answer { devices.hold(usages: Array(0x04...0x24), reply: $0) }
        #expect(refusal?.localizedDescription == "33 keys are down, and one HID keyboard report carries 32")
        #expect(keyboard.log.isEmpty)
    }

    /// Repeating a held set is a report, so it keeps its keys past the limit; a player that
    /// stops repeating loses them.
    @Test func aRepeatedHoldKeepsItsKeysPastTheLimit() {
        let keyboard = RecordingKeyboard()
        let (devices, clock) = timed(keyboard)
        for _ in 0..<5 {
            _ = answer { devices.hold(usages: [0xE1], reply: $0) }
            clock.advance(.seconds(1))
            #expect(devices.releaseKeysHeldPastLimit() == nil)
        }
        clock.advance(.seconds(1))
        #expect(devices.releaseKeysHeldPastLimit()?.usages == [0xE1])
    }

    /// A client that leaves mid-hold has its keys and buttons released, however they came
    /// to be held.
    @Test func aClientLeavingMidHoldIsReleased() {
        let keyboard = RecordingKeyboard()
        let mouse = RecordingMouse()
        let client = NSObject()
        let seat = Seat(ObjectIdentifier(client), pid: 41, holder: Holder(), readiness: .serving(Devices(keyboard: keyboard, mouse: mouse)), cursor: FixedCursor())
        seat.hold(usages: [0xE1, 0x04]) { #expect($0 == nil) }
        seat.holdButtons(1) { #expect($0 == nil) }
        seat.end(because: "a client went away")
        #expect(keyboard.log == ["hold [4, 225]", "up"])
        #expect(keyboard.keysDown.isEmpty)
        #expect(mouse.log == ["hold [1]", "up"])
        withExtendedLifetime(client) {}
    }
}
