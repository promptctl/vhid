import Foundation
import Keystrokes
import Synchronization
import Testing
@testable import VirtualHID

/// A daemon that answers every request and, once the keyboard is initialized, pushes the
/// three statuses a keyboard waits on.
@Sendable private func daemonThatComesUp(_ frame: Frame, _ fake: FakeDaemon) throws {
    guard case .request(let id, let payload) = frame else { return }
    try fake.send(.response(id: id, payload: []))
    if requestSent(payload).request == DaemonConnection.Request.keyboardInitialize.rawValue {
        try fake.push([(.driverActivated, true), (.driverConnected, true)])
        try fake.push([(.keyboardReady, true)])
    }
}

private func keyboard(on fake: FakeDaemon, reportTimeout: Duration = .seconds(2)) throws -> VirtualKeyboard {
    VirtualKeyboard(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor), reportTimeout: reportTimeout)
}

/// The reports the device actually put on the wire, in order.
private func reports(_ fake: FakeDaemon) -> [[UInt8]] {
    fake.requestPayloads.map(requestSent).filter { $0.request == DaemonConnection.Request.postKeyboardInputReport.rawValue }.map(\.bytes)
}

private func report(modifiers: UInt8, _ usages: [UInt16] = []) -> [UInt8] {
    let padded = usages + Array(repeating: 0, count: HeldKeys.capacity - usages.count)
    return [1, modifiers, 0] + padded.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
}

@Suite struct StartupTests {
    /// The parameters are three uint64, little-endian, vendor then product then country.
    /// The plausible reading - two 16-bit ids and a byte - is five bytes long, well formed,
    /// and initializes a device that is not the one asked for.
    @Test func initializeCarriesTheClientVersionAndThreeLittleEndianUInt64Parameters() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        try keyboard(on: fake).start(within: .seconds(2))
        let sent = requestSent(fake.requestPayloads[0])
        #expect(sent.version == 7)
        #expect(sent.request == DaemonConnection.Request.keyboardInitialize.rawValue)
        #expect(sent.bytes == [0xc0, 0x16, 0, 0, 0, 0, 0, 0,
                               0xdb, 0x27, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0])
    }

    /// Readiness is a value the daemon sends and this waits for, never a sleep. A daemon
    /// that takes its time is waited out; one that answers sooner is not waited on longer.
    @Test func startWaitsForTheDaemonsWordAndReturnsWhenItComes() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, let payload) = frame else { return }
            try fake.send(.response(id: id, payload: []))
            if requestSent(payload).request == DaemonConnection.Request.keyboardInitialize.rawValue {
                Thread.sleep(forTimeInterval: 0.2)
                try fake.push([(.keyboardReady, true)])
            }
        }
        let startup = try keyboard(on: fake).start(within: .seconds(5))
        #expect(startup.ready > .milliseconds(180))
        // Well inside the five seconds it was given: it returned when told, not on a timer.
        #expect(startup.ready < .seconds(2))
        // The daemon answered the initialize at once and only then slept; a startup that
        // reported this stall would be timing the next thing the daemon said, not its answer.
        #expect(startup.answered < .milliseconds(100))
    }

    /// A driver built for another protocol accepts reports and then does something other
    /// than what they say, so skew is a hard failure with no degraded mode to continue
    /// into. [LAW:no-silent-failure]
    @Test func aDriverVersionMismatchStopsTheRunRatherThanWarning() {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, _) = frame else { return }
            try fake.send(.response(id: id, payload: []))
            try fake.push([(.driverVersionMismatched, true)])
        }
        #expect(throws: DaemonError.driverVersionMismatched) { try keyboard(on: fake).start(within: .seconds(2)) }
    }

    /// A daemon that says nothing is a named failure at the deadline, not a wait without
    /// end. [LAW:no-silent-failure]
    @Test func aDaemonThatNeverAnswersIsAFailureWithAName() {
        let fake = FakeDaemon { _, _ in }
        #expect(throws: DaemonError.silent) { try keyboard(on: fake).start(within: .milliseconds(200)) }
    }

    /// A daemon that answered and then never said the keyboard is ready is not silent: the
    /// failure is what it did say, which is how an unapproved driver gets named.
    @Test(arguments: [
        ([], "nothing about the driver"),
        ([(.driverActivated, false)], "driver activated: no"),
        ([(.driverConnected, false), (.driverActivated, true)], "driver activated: yes, driver connected: no"),
        ([(.driverConnected, true), (.keyboardReady, false)], "driver connected: yes, keyboard ready: no"),
    ] as [([(DaemonConnection.Status, Bool)], String)])
    func aReadinessTimeoutNamesWhatTheDaemonSaid(pushed: [(DaemonConnection.Status, Bool)], named: String) throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, _) = frame else { return }
            try fake.send(.response(id: id, payload: []))
            try fake.push(pushed)
        }
        let error = try #require(throws: DaemonError.self) { try keyboard(on: fake).start(within: .milliseconds(300)) }
        guard case .notReady(.keyboardReady, _) = error else { Issue.record("threw \(error)"); return }
        #expect(error.description == "the driver's daemon never said keyboard ready; it last said \(named)")
    }

    /// The daemon health-checks its clients, and a client that does not answer is one it
    /// drops. The answer goes out from inside the wait for something else.
    @Test func aHealthCheckIsAnsweredEvenWhileWaitingForSomethingElse() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, _) = frame else { return }
            try fake.send(.control(.healthCheck, payload: []))
            try fake.send(.response(id: id, payload: []))
            try fake.push([(.keyboardReady, true)])
        }
        try keyboard(on: fake).start(within: .seconds(2))
        #expect(fake.awaitFrame(.control(.healthCheckResponse, payload: [])))
    }
}

@Suite struct KeysDownTests {
    /// Every report is a reading of the keys that are down, and a caller never composes
    /// one. [LAW:one-source-of-truth] A report that could disagree with what is held has
    /// exactly one failure mode, and it is the one this whole epic is about.
    @Test func everyReportIsTheKeysDownAndNothingElse() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = try keyboard(on: fake)
        try device.start(within: .seconds(2))
        try device.down(Usage(rawValue: 0x04))
        try device.down(Usage(rawValue: 0x05))
        #expect(device.keysDown == [Usage(rawValue: 0x04), Usage(rawValue: 0x05)])
        try device.up(Usage(rawValue: 0x04))
        try device.releaseAll()
        #expect(device.keysDown.isEmpty)
        #expect(reports(fake) == [
            report(modifiers: 0, [0x04]),
            report(modifiers: 0, [0x04, 0x05]),
            report(modifiers: 0, [0x05]),
            report(modifiers: 0),
        ])
    }

    /// A modifier is a usage like any other, and the bit it sets in the report is derived
    /// from the usage rather than kept beside it. Left shift is 0xE1 and bit 0x02 because
    /// 0xE1 is the second of the eight, not because a table says so.
    @Test func aModifierIsAUsageAndItsBitComesFromTheUsage() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = try keyboard(on: fake)
        try device.start(within: .seconds(2))
        try device.down(.leftShift)
        try device.down(Usage(rawValue: 0x04))
        try device.up(Usage(rawValue: 0x04))
        try device.up(.leftShift)
        #expect(reports(fake) == [
            report(modifiers: 0x02),
            report(modifiers: 0x02, [0x04]),
            report(modifiers: 0x02),
            report(modifiers: 0),
        ])
    }

    /// All eight, each in its own bit and none in another's.
    @Test func theEightModifiersCarryTheEightBitsInOrder() throws {
        let modifiers: [Usage] = [.leftControl, .leftShift, .leftOption, .leftCommand, .rightControl, .rightShift, .rightOption, .rightCommand]
        for (index, modifier) in modifiers.enumerated() {
            #expect(modifier.modifierBit == UInt8(1 << index))
        }
        #expect(Usage(rawValue: 0x04).modifierBit == nil)
        #expect(Usage(rawValue: 0xDF).modifierBit == nil)
        #expect(Usage(rawValue: 0xE8).modifierBit == nil)
        // All eight held at once is every bit set and no key in the usage field.
        #expect(try KeyboardReport(held: Set(modifiers)).bytes == report(modifiers: 0xff))
    }

    /// One set of keys held has one encoding, so a report can be compared against a
    /// capture: without an order, the usage field would vary run to run with a hash seed.
    @Test func theUsagesGoOutInOrderSoOneSetHasOneEncoding() throws {
        let held: Set<Usage> = [Usage(rawValue: 0x0a), Usage(rawValue: 0x04), Usage(rawValue: 0x07)]
        #expect(try KeyboardReport(held: held).bytes == report(modifiers: 0, [0x04, 0x07, 0x0a]))
    }

    /// The 67 bytes of one report, placed by hand.
    ///
    /// Every other byte assertion here compares the module's packing against `report(_:_:)`,
    /// which packs a report the same way the module does - so the one thing those tests
    /// exist to catch, a wrong layout, is the one thing they would agree with. This is the
    /// only place the layout is stated independently of the code that produces it, and
    /// `report(_:_:)` is checked against it here. [LAW:one-source-of-truth]
    @Test func aReportIsSixtySevenBytesLaidOutTheWayTheDriverReadsThem() throws {
        var expected = [UInt8](repeating: 0, count: 67)
        expected[0] = 1     // report id 1, the keyboard collection
        expected[1] = 0x02  // left shift, the second of the eight modifier bits
        expected[2] = 0     // reserved, and it stays reserved
        // Then 32 usages of two bytes each, low byte first - little-endian, unlike the
        // big-endian framing that carries them. The high byte of each is zero here.
        expected[3] = 0x04
        expected[5] = 0x1e
        let held: Set<Usage> = [.leftShift, Usage(rawValue: 0x04), Usage(rawValue: 0x1e)]
        #expect(try KeyboardReport(held: held).bytes == expected)
        #expect(report(modifiers: 0x02, [0x04, 0x1e]) == expected)
    }

    /// The usage field is fixed width. More keys than it carries is refused by name rather
    /// than by dropping one, which would be a key held that no report mentions.
    @Test func moreKeysThanOneReportCarriesIsRefused() throws {
        let thirtyTwo = Set((0x04...0x23).map { Usage(rawValue: UInt16($0)) })
        #expect(thirtyTwo.count == HeldKeys.capacity)
        #expect(throws: Never.self) { try KeyboardReport(held: thirtyTwo) }
        #expect(throws: TooManyKeys.self) { try KeyboardReport(held: thirtyTwo.union([Usage(rawValue: 0x24)])) }
        // Modifiers are not in that field, so eight of them cost nothing against the cap.
        #expect(throws: Never.self) { try KeyboardReport(held: thirtyTwo.union([.leftShift, .rightCommand])) }
    }

    /// A key recorded as down before the report goes out, deliberately: if the post fails
    /// after the driver saw it, a record that already says so is the one releaseAll can
    /// act on. The other order forgets keys that are really held.
    @Test func aKeyIsRecordedDownEvenWhenItsReportFails() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, let payload) = frame else { return }
            guard requestSent(payload).request != DaemonConnection.Request.postKeyboardInputReport.rawValue else { return }
            try fake.send(.response(id: id, payload: []))
        }
        let device = try keyboard(on: fake, reportTimeout: .milliseconds(200))
        #expect(throws: DaemonError.silent) { try device.down(.leftShift) }
        #expect(device.keysDown == [.leftShift])
    }

    /// The mirror of the rule above, and the half that had it backwards: a release the
    /// daemon does not answer leaves the key recorded as held. The record may over-report
    /// what the device is holding and may never under-report, because a key it has already
    /// forgotten is one nothing will lift.
    @Test func aReleaseThatIsNotAnsweredLeavesTheKeyRecordedAsHeld() throws {
        // Presses are answered and the three ways of releasing are not, which is the
        // mid-burst timeout this is about: the report reaching the driver and the answer
        // coming back are two events, and only the second one failed.
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, let payload) = frame else { return }
            let sent = requestSent(payload)
            let releasing = sent.request == DaemonConnection.Request.keyboardReset.rawValue
                || (sent.request == DaemonConnection.Request.postKeyboardInputReport.rawValue
                    && sent.bytes.dropFirst().allSatisfy { $0 == 0 })
            guard !releasing else { return }
            try fake.send(.response(id: id, payload: []))
        }
        let device = try keyboard(on: fake, reportTimeout: .milliseconds(200))
        try device.down(.leftShift)
        #expect(throws: DaemonError.silent) { try device.up(.leftShift) }
        #expect(device.keysDown == [.leftShift])
        #expect(throws: DaemonError.silent) { try device.releaseAll() }
        #expect(device.keysDown == [.leftShift])
        #expect(throws: DaemonError.silent) { try device.reset() }
        #expect(device.keysDown == [.leftShift])
    }

    /// A report this side refuses to encode put no bytes on the wire, so the key it names
    /// is not recorded: the pessimistic bias belongs to the send, which is ambiguous about
    /// what the driver saw, and not to a local refusal, which is not. Recorded anyway, the
    /// over-capacity set would be re-encoded and refused by every later post until some
    /// caller happened to shrink it back under the cap.
    @Test func aKeyNoReportCanCarryIsNotRecordedAsHeld() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = try keyboard(on: fake)
        try device.start(within: .seconds(2))
        let full = (0x04...0x23).map { Usage(rawValue: UInt16($0)) }
        for usage in full { try device.down(usage) }
        #expect(device.keysDown == Set(full))
        #expect(throws: TooManyKeys.self) { try device.down(Usage(rawValue: 0x24)) }
        #expect(device.keysDown == Set(full))
        // Unchanged means still usable: the next post encodes the same 32 keys it always
        // could, where a recorded 33rd would have refused this one too.
        #expect(throws: Never.self) { try device.down(full[0]) }
    }

    /// reset clears the device's own idea of what is held as well as this side's.
    @Test func resetAsksTheDaemonToClearTheDeviceAndForgetsWhatWasHeld() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = try keyboard(on: fake)
        try device.start(within: .seconds(2))
        try device.down(.leftShift)
        try device.reset()
        #expect(device.keysDown.isEmpty)
        let sent = fake.requestPayloads.map(requestSent)
        #expect(sent.last?.request == DaemonConnection.Request.keyboardReset.rawValue)
        #expect(sent.last?.bytes.isEmpty == true)
    }
}

/// A player's held sets: each `hold` is the report of exactly that set, a repeat of the set
/// the driver acknowledged is a keep-alive that posts nothing, and none may be skipped that
/// the driver has not acknowledged.
@Suite struct HoldTests {
    private let post = DaemonConnection.Request.postKeyboardInputReport.rawValue

    /// Whether the fake answers keyboard reports, turned by the test between calls.
    final class Answering: Sendable {
        private let on = Mutex(true)
        var isOn: Bool { on.withLock { $0 } }
        func set(_ value: Bool) { on.withLock { $0 = value } }
    }

    /// A hold replaces what is down rather than adding to it, and every one is a report.
    @Test func aHoldIsTheReportOfExactlyThatSet() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = try keyboard(on: fake)
        try device.start(within: .seconds(2))
        try device.down(Usage(rawValue: 0x04))
        try device.hold(HeldKeys([.leftShift, Usage(rawValue: 0x05)]))
        #expect(device.keysDown == [.leftShift, Usage(rawValue: 0x05)])
        try device.hold(HeldKeys([.leftShift]))
        #expect(reports(fake) == [
            report(modifiers: 0, [0x04]),
            report(modifiers: 0x02, [0x05]),
            report(modifiers: 0x02),
        ])
    }

    /// A non-empty set the driver already acknowledged posts nothing, however often it is
    /// repeated; an empty one posts every time, because a final all-up report is the line
    /// between a run that ends and a key macOS repeats.
    @Test func aRepeatedSetPostsNothingAndAnEmptyOneAlwaysPosts() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = try keyboard(on: fake)
        try device.start(within: .seconds(2))
        let shift = try HeldKeys([.leftShift])
        try device.hold(shift)
        try device.hold(shift)
        try device.hold(shift)
        try device.hold(.none)
        try device.hold(.none)
        #expect(reports(fake) == [report(modifiers: 0x02), report(modifiers: 0), report(modifiers: 0)])
    }

    /// The set a key was pressed by through `down` is acknowledged as well: a hold of it
    /// is a keep-alive, as it is after a hold.
    @Test func aSetReachedByDownIsAcknowledgedToo() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = try keyboard(on: fake)
        try device.start(within: .seconds(2))
        try device.down(.leftShift)
        try device.hold(HeldKeys([.leftShift]))
        #expect(reports(fake) == [report(modifiers: 0x02)])
    }

    /// A hold that threw leaves nothing acknowledged, so its retry posts. Compared against
    /// `keysDown` instead, which took on the failed set before the request, the retry would
    /// be skipped and its key never pressed.
    @Test func theRetryOfAHoldThatThrewPosts() throws {
        let answering = Answering()
        let post = post
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, let payload) = frame else { return }
            guard requestSent(payload).request != post || answering.isOn else { return }
            try fake.send(.response(id: id, payload: []))
        }
        let device = try keyboard(on: fake, reportTimeout: .milliseconds(200))
        let shift = try HeldKeys([.leftShift])
        let shiftB = try HeldKeys([.leftShift, Usage(rawValue: 0x05)])
        try device.hold(shift)
        answering.set(false)
        #expect(throws: DaemonError.silent) { try device.hold(shiftB) }
        #expect(device.keysDown == shiftB.usages)
        answering.set(true)
        try device.hold(shiftB)
        try device.hold(shiftB)
        #expect(reports(fake) == [report(modifiers: 0x02), report(modifiers: 0x02, [0x05]), report(modifiers: 0x02, [0x05])])
    }

    /// A reset leaves the driver holding nothing, and a hold after it posts.
    @Test func aHoldAfterAResetPosts() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = try keyboard(on: fake)
        try device.start(within: .seconds(2))
        let shift = try HeldKeys([.leftShift])
        try device.hold(shift)
        try device.reset()
        try device.hold(shift)
        #expect(reports(fake) == [report(modifiers: 0x02), report(modifiers: 0x02)])
    }
}

