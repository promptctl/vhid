import Foundation
import Helper
import Keystrokes
import Pointing
import Synchronization
import TestClock
import Testing
import Time
@testable import vhidd

/// The devices as vhidd serves them, over recording devices of the test's own: what
/// the wire may carry that the device cannot, when an act's turn comes, and what a client
/// leaving lets go of.
@Suite struct DevicesTests {
    /// Holds keys the way the device does: noted before the request, which may throw
    /// having reached the driver, and cleared only by a release that succeeds. A key-down
    /// can be made to wait at `gate`, holding the devices' lock as a slow driver does.
    final class RecordingKeyboard: HeldKeyboard {
        private let recorded = Mutex<[String]>([])
        private let held = Mutex<Set<Usage>>([])
        let refusesRelease: Mutex<Bool>
        let refusesDown: Bool
        let gate: Handshake?

        init(refusesRelease: Bool = false, refusesDown: Bool = false, gate: Handshake? = nil) {
            self.refusesRelease = Mutex(refusesRelease)
            self.refusesDown = refusesDown
            self.gate = gate
        }

        var log: [String] { recorded.withLock { $0 } }
        var keysDown: Set<Usage> { held.withLock { $0 } }

        func down(_ usage: Usage, by deadline: Deadline) throws {
            recorded.withLock { $0.append("down \(usage.rawValue)") }
            held.withLock { _ = $0.insert(usage) }
            gate?.arrive()
            if refusesDown { throw Refused() }
        }
        func releaseAll(by deadline: Deadline) throws {
            recorded.withLock { $0.append("up") }
            if refusesRelease.withLock({ $0 }) { throw Refused() }
            held.withLock { $0 = [] }
        }
        func hold(_ keys: HeldKeys, by deadline: Deadline) throws {
            recorded.withLock { $0.append("hold \(keys.usages.map(\.rawValue).sorted())") }
            held.withLock { $0 = keys.usages }
        }
    }

    final class RecordingMouse: HeldMouse {
        private let recorded = Mutex<[String]>([])

        var log: [String] { recorded.withLock { $0 } }
        var buttonsDown: Set<Button> { [] }

        func down(_ button: Button, by deadline: Deadline) throws { recorded.withLock { $0.append("down \(button.rawValue)") } }
        func releaseAll(by deadline: Deadline) throws { recorded.withLock { $0.append("up") } }
        func hold(_ buttons: Set<Button>, by deadline: Deadline) throws { recorded.withLock { $0.append("hold \(buttons.map(\.rawValue).sorted())") } }
        func move(_ delta: Move, by deadline: Deadline) throws { recorded.withLock { $0.append("move \(delta.x.value) \(delta.y.value)") } }
        func scroll(_ delta: Scroll, by deadline: Deadline) throws { recorded.withLock { $0.append("scroll \(delta.vertical.value) \(delta.horizontal.value)") } }
    }

    struct Refused: Error {}

    /// What parsing `act` threw, in the words a client reads.
    private func refused(_ act: () throws -> Act) -> String? {
        do {
            _ = try act()
            return nil
        } catch {
            return refusal(error).localizedDescription
        }
    }

    /// A button the device has no bit for, or a count the descriptor does not admit, is
    /// refused by name as the act is read off the wire, before any device sees it.
    /// [LAW:parse-dont-validate]
    @Test func valuesTheDeviceCannotCarryAreRefusedAsTheActIsRead() {
        #expect(refused { try .buttonDown(0) } == "button 0 is not one of the 32 the device has a bit for")
        #expect(refused { try .buttonDown(33) } == "button 33 is not one of the 32 the device has a bit for")
        #expect(refused { try .move(x: -128, y: 0) } == "-128 is outside the -127 through 127 a report carries")
        #expect(refused { try .scroll(vertical: 1, horizontal: -128) } == "-128 is outside the -127 through 127 a report carries")
        #expect(refused { try .down(usage: 3) } == "usage 3 is not one of the keys 4 through 231")
        #expect(refused { try .hold(usages: [0xE1, 0xE8]) } == "usage 232 is not one of the keys 4 through 231")
        #expect(refused { try .hold(usages: Array(0x04...0x24)) } == "33 keys are down, and one HID keyboard report carries 32")
    }

    /// A refusal crosses as the one error a client can decode, carrying the words.
    @Test func aRefusalCrossesAsAnNSErrorCarryingItsDescription() {
        let error = refusal(NotOnTheDevice.button(0))
        #expect(error.domain == "ai.promptctl.vhid.vhidd.refusal")
        #expect(error.localizedDescription == "button 0 is not one of the 32 the device has a bit for")
    }

    private func devices(_ keyboard: RecordingKeyboard = RecordingKeyboard(), _ mouse: RecordingMouse = RecordingMouse()) -> (Devices, ManualClock) {
        let clock = ManualClock()
        return (Devices(keyboard: keyboard, mouse: mouse, timeline: clock.timeline, limit: .seconds(2)), clock)
    }

    /// An act with no seat to admit, by a deadline five seconds off.
    private func act(_ act: Act, on devices: Devices, _ clock: ManualClock) throws {
        try devices.act(act, by: .within(.seconds(5), on: clock.timeline)) {}
    }

    /// What the device can carry reaches it as asked.
    @Test func actsReachTheDeviceAsAsked() throws {
        let (keyboard, mouse) = (RecordingKeyboard(), RecordingMouse())
        let (devices, clock) = devices(keyboard, mouse)
        try act(.down(.a), on: devices, clock)
        try act(.buttonDown(try #require(Button(rawValue: 3))), on: devices, clock)
        try act(try .move(x: 127, y: -127), on: devices, clock)
        try act(try .scroll(vertical: 1, horizontal: -1), on: devices, clock)
        try act(.releaseButtons, on: devices, clock)
        try act(.releaseKeys, on: devices, clock)
        try act(try .hold(usages: [0xE1, 0x04, 0x04]), on: devices, clock)
        try act(.holdButtons(0b101), on: devices, clock)
        try act(.holdButtons(1 << 31), on: devices, clock)
        #expect(keyboard.log == ["down 4", "up", "hold [4, 225]"])
        #expect(mouse.log == ["down 3", "move 127 -127", "scroll 1 -1", "up", "hold [1, 3]", "hold [32]"])
    }

    /// An act whose turn at the devices comes after its client stopped waiting is refused
    /// for its deadline, having claimed nothing and sent nothing: the client was told it
    /// failed, so the devices must not do it later. [LAW:no-ambient-temporal-coupling]
    @Test func anActWhoseTurnComesAfterItsDeadlineIsRefusedHavingDoneNothing() throws {
        let gate = Handshake()
        let keyboard = RecordingKeyboard(gate: gate)
        let (devices, clock) = devices(keyboard)
        let ahead = Pending { try devices.act(.down(.a), by: .within(.seconds(5), on: clock.timeline)) {} }
        try #require(gate.reached.wait("the act ahead to hold the devices"))
        let admitted = Mutex(false)
        let late = Pending { try devices.act(.down(.b), by: .within(.seconds(1), on: clock.timeline)) { admitted.withLock { $0 = true } } }
        clock.awaitBlocked(1)
        clock.advance(by: .seconds(1))
        #expect(throws: Deadline.Passed.self) { try late.get() }
        gate.released.open()
        try ahead.get()
        #expect(!admitted.withLock { $0 })
        #expect(keyboard.log == ["down 4"])
    }

    /// An act the seat does not admit sends nothing.
    @Test func anActTheSeatRefusesSendsNothing() {
        let keyboard = RecordingKeyboard()
        let (devices, clock) = devices(keyboard)
        #expect(throws: Holder.Busy.self) { try devices.act(.down(.a), by: .within(.seconds(5), on: clock.timeline)) { throw Holder.Busy(pid: 41) } }
        #expect(keyboard.log.isEmpty)
    }

    /// A release lets go of both devices, the mouse whatever the keyboard said, and says
    /// which would not; until a release lands the devices read as left held.
    @Test func aReleaseReleasesBothDevicesWhateverTheKeyboardAnswers() {
        let (keyboard, mouse) = (RecordingKeyboard(refusesRelease: true), RecordingMouse())
        let (devices, _) = devices(keyboard, mouse)
        #expect(devices.releaseEverything(because: "the client went away") == Released(keyboard: "\(Refused())", mouse: nil))
        #expect(keyboard.log == ["up"])
        #expect(mouse.log == ["up"])
        #expect(devices.leftHeld)
        keyboard.refusesRelease.withLock { $0 = false }
        #expect(devices.releaseEverything(because: "vhidd is stopping") == Released(keyboard: nil, mouse: nil))
        #expect(!devices.leftHeld)
    }

    /// A release a seat no longer owes - its hold freed by a lost bring-up, say - releases
    /// nothing and frees nothing.
    @Test func aReleaseNoLongerOwedDoesNothing() {
        let keyboard = RecordingKeyboard()
        let (devices, _) = devices(keyboard)
        var freed = false
        #expect(devices.release(because: "a client left", when: { false }, then: { freed = true }) == nil)
        #expect(!freed)
        #expect(keyboard.log.isEmpty)
    }

    /// What a failed release left is released again by the sweep while nobody holds the
    /// devices, one limit after the failure, and never while a client holds them.
    @Test func whatAFailedReleaseLeftIsReleasedAgainWhileNobodyHoldsTheDevices() {
        let keyboard = RecordingKeyboard(refusesRelease: true)
        let (devices, clock) = devices(keyboard)
        _ = devices.releaseEverything(because: "a client left")
        keyboard.refusesRelease.withLock { $0 = false }
        clock.advance(by: .milliseconds(1999))
        #expect(devices.sweep(holding: { nil }) == nil)
        clock.advance(by: .milliseconds(1))
        if case .leftHeld = devices.sweep(holding: { 41 }) { Issue.record("re-released under a client that holds the devices") }
        #expect(devices.leftHeld)
        #expect(devices.sweep(holding: { nil }) == .leftHeld(Released(keyboard: nil, mouse: nil)))
        #expect(!devices.leftHeld)
    }

    /// A key left down with no keyboard report after it is released once the limit passes,
    /// naming the usages, and not before.
    @Test func aKeyHeldPastTheLimitIsReleased() throws {
        let keyboard = RecordingKeyboard()
        let (devices, clock) = devices(keyboard)
        try act(.down(.leftCommand), on: devices, clock)
        try act(.down(.a), on: devices, clock)
        clock.advance(by: .milliseconds(1999))
        #expect(devices.sweep(holding: { nil }) == nil)
        clock.advance(by: .milliseconds(1))
        #expect(devices.sweep(holding: { 7 }) == .keysPastLimit(KeysLetGo(usages: [0x04, 0xE3], limit: .seconds(2), failure: nil), by: 7))
        #expect(keyboard.log == ["down 227", "down 4", "up"])
        clock.advance(by: .seconds(5))
        #expect(devices.sweep(holding: { nil }) == nil)
    }

    /// Chords one after another, each well inside the limit, are never cut, however long
    /// the stream runs; nothing down means nothing to release.
    @Test func aSteadyStreamOfChordsIsNeverInterrupted() throws {
        let keyboard = RecordingKeyboard()
        let (devices, clock) = devices(keyboard)
        for _ in 0..<20 {
            try act(.down(.leftShift), on: devices, clock)
            clock.advance(by: .milliseconds(900))
            #expect(devices.sweep(holding: { nil }) == nil)
            try act(.down(.b), on: devices, clock)
            clock.advance(by: .milliseconds(900))
            #expect(devices.sweep(holding: { nil }) == nil)
            try act(.releaseKeys, on: devices, clock)
            clock.advance(by: .seconds(10))
            #expect(devices.sweep(holding: { nil }) == nil)
        }
        #expect(keyboard.log.count == 60)
    }

    /// A button held past the limit stays down: a replayed pointer script holds one across gaps.
    @Test func aButtonHeldPastTheLimitIsNotReleased() throws {
        let mouse = RecordingMouse()
        let (devices, clock) = devices(RecordingKeyboard(), mouse)
        try act(.buttonDown(.left), on: devices, clock)
        clock.advance(by: .seconds(30))
        #expect(devices.sweep(holding: { nil }) == nil)
        #expect(mouse.log == ["down 1"])
    }

    /// A key release the keyboard refused is reported and tried again one limit later.
    @Test func aRefusedReleaseIsReportedAndRetriedAfterTheLimit() throws {
        let (devices, clock) = devices(RecordingKeyboard(refusesRelease: true))
        try act(.down(.a), on: devices, clock)
        clock.advance(by: .seconds(2))
        guard case .keysPastLimit(let first, _) = devices.sweep(holding: { nil }) else { Issue.record("nothing was let go"); return }
        #expect(first.failure != nil)
        clock.advance(by: .milliseconds(250))
        #expect(devices.sweep(holding: { nil }) == nil)
        clock.advance(by: .milliseconds(1750))
        guard case .keysPastLimit(let again, _) = devices.sweep(holding: { nil }) else { Issue.record("nothing was let go again"); return }
        #expect(again.usages == [0x04])
    }

    /// A key whose request threw after reaching the driver is still down on the device,
    /// and the sweep releases it.
    @Test func aKeyWhoseRequestThrewIsStillReleased() throws {
        let (devices, clock) = devices(RecordingKeyboard(refusesDown: true))
        #expect(throws: Refused.self) { try act(.down(.a), on: devices, clock) }
        clock.advance(by: .seconds(2))
        #expect(devices.sweep(holding: { nil }) == .keysPastLimit(KeysLetGo(usages: [0x04], limit: .seconds(2), failure: nil), by: nil))
    }

    /// A modifier held through a drag the client paces over seconds is live: every pointer
    /// report counts, and the modifier stays down.
    @Test func aModifierHeldThroughAPacedDragIsNotCut() throws {
        let (devices, clock) = devices()
        try act(.down(.leftOption), on: devices, clock)
        try act(.buttonDown(.left), on: devices, clock)
        for _ in 0..<30 {
            clock.advance(by: .milliseconds(200))
            try act(try .move(x: 5, y: 0), on: devices, clock)
            #expect(devices.sweep(holding: { nil }) == nil)
        }
    }

    /// Repeating a held set is a report, so it keeps its keys past the limit; a player that
    /// stops repeating loses them.
    @Test func aRepeatedHoldKeepsItsKeysPastTheLimit() throws {
        let (devices, clock) = devices()
        for _ in 0..<5 {
            try act(try .hold(usages: [0xE1]), on: devices, clock)
            clock.advance(by: .seconds(1))
            #expect(devices.sweep(holding: { nil }) == nil)
        }
        clock.advance(by: .seconds(1))
        #expect(devices.sweep(holding: { nil }) == .keysPastLimit(KeysLetGo(usages: [0xE1], limit: .seconds(2), failure: nil), by: nil))
    }

    /// The sweep releases the keys and leaves the devices with the client that held them,
    /// and the log names that client and the keys.
    @Test func theHolderStillBelongsToTheClientAfterwards() throws {
        let (devices, clock) = devices()
        let readiness = Readiness.serving(devices)
        let holder = Holder()
        // Kept alive, so the two identifiers cannot share a freed address.
        let (first, second) = (NSObject(), NSObject())
        let attempt = try readiness.devices().attempt
        try devices.act(.down(.a), by: .within(.seconds(5), on: clock.timeline)) { try holder.claim(for: ObjectIdentifier(first), by: 4242, on: attempt) }
        clock.advance(by: .seconds(3))
        #expect(sweep(readiness, holder) == "pid 4242 held 0x04 past 2.0 seconds with no report; released")
        #expect(holder.pid(on: attempt) == 4242)
        #expect(throws: Holder.Busy.self) { try holder.claim(for: ObjectIdentifier(second), by: 1, on: attempt) }
        withExtendedLifetime((first, second)) {}
    }

    /// A client that leaves mid-hold has its keys and buttons released, however they came
    /// to be held.
    @Test func aClientLeavingMidHoldIsReleased() {
        let (keyboard, mouse) = (RecordingKeyboard(), RecordingMouse())
        let (devices, clock) = devices(keyboard, mouse)
        let client = NSObject()
        let seat = Seat(ObjectIdentifier(client), pid: 41, holder: Holder(), readiness: .serving(devices), screen: FixedScreen(), timeline: clock.timeline)
        let by = Deadline.within(.seconds(5), on: clock.timeline).at.nanoseconds
        seat.hold(usages: [0xE1, 0x04], by: by) { #expect($0 == nil) }
        seat.holdButtons(1, by: by) { #expect($0 == nil) }
        #expect(seat.end(because: "a client went away") == Released(keyboard: nil, mouse: nil))
        #expect(keyboard.log == ["hold [4, 225]", "up"])
        #expect(keyboard.keysDown.isEmpty)
        #expect(mouse.log == ["hold [1]", "up"])
        withExtendedLifetime(client) {}
    }
}

private extension Usage {
    static let a = Usage(rawValue: 0x04)
    static let b = Usage(rawValue: 0x05)
}
