import Foundation
import Keystrokes
import Synchronization
import OwnThread
import TestClock
import Testing
import Time
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

/// A daemon that answers every request but the keyboard reports `unanswered` picks out.
private func daemon(leavingUnanswered unanswered: @escaping @Sendable ([UInt8]) -> Bool) -> FakeDaemon {
    FakeDaemon { frame, fake in
        guard case .request(let id, let payload) = frame else { return }
        let sent = requestSent(payload)
        guard sent.request != DaemonConnection.Request.postKeyboardInputReport.rawValue || !unanswered(sent.bytes) else { return }
        try fake.send(.response(id: id, payload: []))
    }
}

/// A keyboard over `fake`, its waits on `clock`.
private func keyboard(on fake: FakeDaemon, _ clock: ManualClock) throws -> VirtualKeyboard {
    VirtualKeyboard(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor, timeline: clock.timeline))
}

/// A deadline nothing in the test reaches, on a clock nothing moves.
private func unhurried(_ clock: ManualClock) -> Deadline { .within(.seconds(2), on: clock.timeline) }

/// The reports the device actually put on the wire, in order.
private func reports(_ fake: FakeDaemon) -> [[UInt8]] {
    fake.requestPayloads.map(requestSent).filter { $0.request == DaemonConnection.Request.postKeyboardInputReport.rawValue }.map(\.bytes)
}

private func report(modifiers: UInt8, _ usages: [UInt16] = []) -> [UInt8] {
    let padded = usages + Array(repeating: 0, count: HeldKeys.capacity - usages.count)
    return [1, modifiers, 0] + padded.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
}

/// Whether a report's bytes hold nothing: the release.
@Sendable private func releasing(_ bytes: [UInt8]) -> Bool { bytes.dropFirst().allSatisfy { $0 == 0 } }

@Suite(.ownThread) struct StartupTests {
    /// The parameters are three uint64, little-endian, vendor then product then country.
    /// The plausible reading - two 16-bit ids and a byte - is five bytes long, well formed,
    /// and initializes a device that is not the one asked for.
    @Test func initializeCarriesTheClientVersionAndThreeLittleEndianUInt64Parameters() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        try keyboard(on: fake, clock).start(by: unhurried(clock))
        let sent = requestSent(fake.requestPayloads[0])
        #expect(sent.version == 7)
        #expect(sent.request == DaemonConnection.Request.keyboardInitialize.rawValue)
        #expect(sent.bytes == [0xc0, 0x16, 0, 0, 0, 0, 0, 0,
                               0xdb, 0x27, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0])
    }

    /// Readiness is a value the daemon sends and this waits for, never a sleep: the start
    /// returns when the word comes, and says when the daemon answered and when it was
    /// ready, each counted from when the start was asked.
    @Test func startWaitsForTheDaemonsWordAndReturnsWhenItComes() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        let starting = Pending { try device.start(by: .within(.seconds(5), on: clock.timeline)) }
        fake.awaitRequests(1)
        // The answer has been read, and the start is waiting for the word.
        try fake.settle()
        clock.advance(by: .milliseconds(200))
        try fake.push([(.keyboardReady, true)])
        let startup = try starting.get()
        // Answered at once; a startup that reported the wait would be timing the next
        // thing the daemon said, not its answer.
        #expect(startup.answered == .zero)
        #expect(startup.ready == .milliseconds(200))
    }

    /// A driver built for another protocol accepts reports and then does something other
    /// than what they say, so skew is a hard failure with no degraded mode to continue
    /// into. [LAW:no-silent-failure]
    @Test func aDriverVersionMismatchStopsTheRunRatherThanWarning() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, _) = frame else { return }
            try fake.send(.response(id: id, payload: []))
            try fake.push([(.driverVersionMismatched, true)])
        }
        let clock = ManualClock()
        #expect(throws: DaemonError.driverVersionMismatched) { try keyboard(on: fake, clock).start(by: unhurried(clock)) }
    }

    /// A daemon that says nothing is a named failure at the deadline, not a wait without
    /// end. [LAW:no-silent-failure]
    @Test func aDaemonThatNeverAnswersIsAFailureWithAName() throws {
        let fake = FakeDaemon { _, _ in }, clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        #expect(try givenUpOn(fake, clock, atRequest: 1) { _ = try device.start(by: $0) } == silent())
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
        let clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        let starting = Pending { try device.start(by: .within(.milliseconds(300), on: clock.timeline)) }
        fake.awaitRequests(1)
        try fake.settle()
        clock.advance(by: .milliseconds(300))
        let error = try #require(throws: DaemonError.self) { try starting.get() }
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
        let clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.start(by: unhurried(clock))
        // Held until the answer is seen: the start returns once the device is ready, with
        // the answer perhaps still queued, and a connection let go hangs up unwritten.
        #expect(fake.awaitFrame(.control(.healthCheckResponse, payload: [])))
        withExtendedLifetime(device) {}
    }
}

@Suite(.ownThread) struct KeysDownTests {
    /// Every report is a reading of the keys that are down, and a caller never composes
    /// one. [LAW:one-source-of-truth] A report that could disagree with what is held has
    /// exactly one failure mode, and it is the one this whole epic is about.
    @Test func everyReportIsTheKeysDownAndNothingElse() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.start(by: unhurried(clock))
        try device.down(Usage(rawValue: 0x04), by: unhurried(clock))
        try device.down(Usage(rawValue: 0x05), by: unhurried(clock))
        #expect(device.keysDown == [Usage(rawValue: 0x04), Usage(rawValue: 0x05)])
        try device.up(Usage(rawValue: 0x04), by: unhurried(clock))
        try device.releaseAll(by: unhurried(clock))
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
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.start(by: unhurried(clock))
        try device.down(.leftShift, by: unhurried(clock))
        try device.down(Usage(rawValue: 0x04), by: unhurried(clock))
        try device.up(Usage(rawValue: 0x04), by: unhurried(clock))
        try device.up(.leftShift, by: unhurried(clock))
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

    /// A press the driver did not answer may have reached it, so the key is recorded as
    /// one it may hold: a record that says so is the one a release can act on.
    @Test func aKeyIsRecordedAsMaybeHeldWhenItsReportGoesUnanswered() throws {
        let fake = daemon(leavingUnanswered: { _ in true }), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        #expect(try givenUpOn(fake, clock, atRequest: 1) { try device.down(.leftShift, by: $0) } == silent())
        #expect(device.keysDown == [.leftShift])
    }

    /// A report never sent cannot have reached the driver, so the record stays as it was:
    /// a key pressed with its limit already passed is not one anything need release.
    @Test func aReportNeverSentLeavesTheRecordAsItWas() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.down(.leftShift, by: unhurried(clock))
        let late = Deadline.within(.milliseconds(10), on: clock.timeline)
        clock.advance(by: .milliseconds(10))
        #expect(throws: Unanswered(reach: .unsent, cause: .deadline(Deadline.Passed(limit: .milliseconds(10), spent: .milliseconds(10))))) { try device.down(Usage(rawValue: 0x04), by: late) }
        #expect(device.keysDown == [.leftShift])
        try device.down(Usage(rawValue: 0x05), by: unhurried(clock))
        #expect(reports(fake) == [report(modifiers: 0x02), report(modifiers: 0x02, [0x05])])
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
            let releases = sent.request == DaemonConnection.Request.keyboardReset.rawValue
                || (sent.request == DaemonConnection.Request.postKeyboardInputReport.rawValue && releasing(sent.bytes))
            guard !releases else { return }
            try fake.send(.response(id: id, payload: []))
        }
        let clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.down(.leftShift, by: unhurried(clock))
        #expect(try givenUpOn(fake, clock, atRequest: 2) { try device.up(.leftShift, by: $0) } == silent())
        #expect(device.keysDown == [.leftShift])
        #expect(try givenUpOn(fake, clock, atRequest: 3) { try device.releaseAll(by: $0) } == silent())
        #expect(device.keysDown == [.leftShift])
        #expect(try givenUpOn(fake, clock, atRequest: 4) { try device.reset(by: $0) } == silent())
        #expect(device.keysDown == [.leftShift])
    }

    /// The next report is built from what the driver was last asked to hold, never from
    /// what it may be holding: after a release that went unanswered, a press holds only
    /// the key pressed, where one built from the record would press shift again.
    @Test func theNextReportIsWhatWasLastAskedNotWhatMayBeHeld() throws {
        let unanswered = Watched(true)
        let fake = daemon(leavingUnanswered: { releasing($0) && unanswered.current })
        let clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.down(.leftShift, by: unhurried(clock))
        #expect(try givenUpOn(fake, clock, atRequest: 2) { try device.releaseAll(by: $0) } == silent())
        unanswered.withLock { $0 = false }
        try device.down(Usage(rawValue: 0x04), by: unhurried(clock))
        #expect(device.keysDown == [Usage(rawValue: 0x04)])
        #expect(reports(fake) == [report(modifiers: 0x02), report(modifiers: 0), report(modifiers: 0, [0x04])])
    }

    /// A report this side refuses to encode put no bytes on the wire, so the key it names
    /// is not recorded: the pessimistic bias belongs to the send, which is ambiguous about
    /// what the driver saw, and not to a local refusal, which is not. Recorded anyway, the
    /// over-capacity set would be re-encoded and refused by every later post until some
    /// caller happened to shrink it back under the cap.
    @Test func aKeyNoReportCanCarryIsNotRecordedAsHeld() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.start(by: unhurried(clock))
        let full = (0x04...0x23).map { Usage(rawValue: UInt16($0)) }
        for usage in full { try device.down(usage, by: unhurried(clock)) }
        #expect(device.keysDown == Set(full))
        #expect(throws: TooManyKeys.self) { try device.down(Usage(rawValue: 0x24), by: unhurried(clock)) }
        #expect(device.keysDown == Set(full))
        // Unchanged means still usable: the next post encodes the same 32 keys it always
        // could, where a recorded 33rd would have refused this one too.
        #expect(throws: Never.self) { try device.down(full[0], by: unhurried(clock)) }
    }

    /// reset clears the device's own idea of what is held as well as this side's.
    @Test func resetAsksTheDaemonToClearTheDeviceAndForgetsWhatWasHeld() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.start(by: unhurried(clock))
        try device.down(.leftShift, by: unhurried(clock))
        try device.reset(by: unhurried(clock))
        #expect(device.keysDown.isEmpty)
        let sent = fake.requestPayloads.map(requestSent)
        #expect(sent.last?.request == DaemonConnection.Request.keyboardReset.rawValue)
        #expect(sent.last?.bytes.isEmpty == true)
    }
}

/// A player's held sets: each `hold` is the report of exactly that set, a repeat of the set
/// the driver acknowledged is a keep-alive that posts nothing, and none may be skipped that
/// the driver has not acknowledged.
@Suite(.ownThread) struct HoldTests {
    /// A hold replaces what is down rather than adding to it, and every one is a report.
    @Test func aHoldIsTheReportOfExactlyThatSet() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.start(by: unhurried(clock))
        try device.down(Usage(rawValue: 0x04), by: unhurried(clock))
        try device.hold(HeldKeys([.leftShift, Usage(rawValue: 0x05)]), by: unhurried(clock))
        #expect(device.keysDown == [.leftShift, Usage(rawValue: 0x05)])
        try device.hold(HeldKeys([.leftShift]), by: unhurried(clock))
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
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.start(by: unhurried(clock))
        let shift = try HeldKeys([.leftShift])
        try device.hold(shift, by: unhurried(clock))
        try device.hold(shift, by: unhurried(clock))
        try device.hold(shift, by: unhurried(clock))
        try device.hold(.none, by: unhurried(clock))
        try device.hold(.none, by: unhurried(clock))
        #expect(reports(fake) == [report(modifiers: 0x02), report(modifiers: 0), report(modifiers: 0)])
    }

    /// The set a key was pressed by through `down` is acknowledged as well: a hold of it
    /// is a keep-alive, as it is after a hold.
    @Test func aSetReachedByDownIsAcknowledgedToo() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.start(by: unhurried(clock))
        try device.down(.leftShift, by: unhurried(clock))
        try device.hold(HeldKeys([.leftShift]), by: unhurried(clock))
        #expect(reports(fake) == [report(modifiers: 0x02)])
    }

    /// A hold that went unanswered leaves nothing acknowledged, so its retry posts: the
    /// driver may hold the set or the one before it, and only a report says which.
    @Test func theRetryOfAHoldThatWentUnansweredPosts() throws {
        let unanswered = Watched(false)
        let fake = daemon(leavingUnanswered: { _ in unanswered.current })
        let clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        let shift = try HeldKeys([.leftShift])
        let shiftB = try HeldKeys([.leftShift, Usage(rawValue: 0x05)])
        try device.hold(shift, by: unhurried(clock))
        unanswered.withLock { $0 = true }
        #expect(try givenUpOn(fake, clock, atRequest: 2) { try device.hold(shiftB, by: $0) } == silent())
        #expect(device.keysDown == shiftB.usages)
        unanswered.withLock { $0 = false }
        try device.hold(shiftB, by: unhurried(clock))
        try device.hold(shiftB, by: unhurried(clock))
        #expect(reports(fake) == [report(modifiers: 0x02), report(modifiers: 0x02, [0x05]), report(modifiers: 0x02, [0x05])])
    }

    /// A reset leaves the driver holding nothing, and a hold after it posts.
    @Test func aHoldAfterAResetPosts() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp), clock = ManualClock()
        let device = try keyboard(on: fake, clock)
        try device.start(by: unhurried(clock))
        let shift = try HeldKeys([.leftShift])
        try device.hold(shift, by: unhurried(clock))
        try device.reset(by: unhurried(clock))
        try device.hold(shift, by: unhurried(clock))
        #expect(reports(fake) == [report(modifiers: 0x02), report(modifiers: 0x02)])
    }
}

