import Foundation
import Pointing
import OwnThread
import TestClock
import Testing
import Time
@testable import VirtualHID

/// A daemon that answers every request and, once the pointing device is initialized,
/// pushes the readiness the real one pushes.
@Sendable private func daemonWhoseMouseComesUp(_ frame: Frame, _ fake: FakeDaemon) throws {
    guard case .request(let id, let payload) = frame else { return }
    try fake.send(.response(id: id, payload: []))
    if requestSent(payload).request == DaemonConnection.Request.pointingInitialize.rawValue {
        try fake.push([(.driverActivated, true), (.driverConnected, true)])
        try fake.push([(.pointingReady, true)])
    }
}

/// A mouse over `fake`, its waits on `clock`.
private func mouse(on fake: FakeDaemon, _ clock: ManualClock) throws -> VirtualPointing {
    VirtualPointing(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock)))
}

/// A deadline nothing in the test reaches, on a clock nothing moves.
private func unhurried(_ clock: ManualClock) -> Deadline { .within(.seconds(2), on: Clock(clock)) }

/// The pointing reports the device actually put on the wire, in order.
private func pointingReports(_ fake: FakeDaemon) -> [[UInt8]] {
    fake.requestPayloads.map(requestSent).filter { $0.request == DaemonConnection.Request.postPointingInputReport.rawValue }.map(\.bytes)
}

@Suite(.ownThread) struct PointingStartupTests {
    /// `pointing_initialize` carries nothing after the request byte, and the wait is for
    /// the pointing device's own readiness: a daemon whose keyboard is ready has said
    /// nothing about its mouse.
    @Test func initializeCarriesNoPayloadAndWaitsForThePointingDevice() throws {
        let fake = FakeDaemon(handling: daemonWhoseMouseComesUp), clock = ManualClock()
        try mouse(on: fake, clock).start(by: unhurried(clock))
        let sent = requestSent(fake.requestPayloads[0])
        #expect(sent.version == 7)
        #expect(sent.request == DaemonConnection.Request.pointingInitialize.rawValue)
        #expect(sent.bytes.isEmpty)
    }

    @Test func aKeyboardThatIsReadyIsNotAMouseThatIsReady() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, _) = frame else { return }
            try fake.send(.response(id: id, payload: []))
            try fake.push([(.keyboardReady, true)])
        }
        let clock = ManualClock()
        let device = try mouse(on: fake, clock)
        let starting = Future { try device.start(by: .within(.milliseconds(200), on: Clock(clock))) }
        fake.awaitRequests(1)
        try fake.settle()
        clock.advance(by: .milliseconds(200))
        #expect(throws: DaemonError.notReady(awaiting: .pointingReady, said: [.keyboardReady: true])) { try starting.get() }
    }
}

@Suite(.ownThread) struct ButtonsDownTests {
    /// The 8 bytes of one report, placed by hand: the one place the layout is stated
    /// independently of the code that produces it. [LAW:one-source-of-truth]
    @Test func aReportIsEightBytesLaidOutTheWayTheDriverReadsThem() {
        let held: Set<Button> = [.left, Button(rawValue: 9)!]
        let report = PointingReport(held: held, move: Move(x: Count(clamping: -3), y: Count(clamping: 5)), scroll: Scroll(vertical: Count(clamping: -1), horizontal: Count(clamping: 127)))
        #expect(report.bytes == [
            0x01, 0x01, 0x00, 0x00, // buttons 1 and 9: bits 0 and 8, little-endian
            0xfd,                   // x -3
            0x05,                   // y 5, positive downward
            0xff,                   // vertical wheel -1
            0x7f,                   // horizontal wheel 127
        ])
    }

    /// Every report is the buttons down plus this report's motion, and motion carries the
    /// buttons: that is what makes a drag a down, moves, and a release.
    @Test func motionAndWheelCarryTheButtonsHeld() throws {
        let fake = FakeDaemon(handling: daemonWhoseMouseComesUp), clock = ManualClock()
        let device = try mouse(on: fake, clock)
        try device.start(by: unhurried(clock))
        try device.down(.left, by: unhurried(clock))
        try device.move(Move(x: Count(clamping: 10), y: Count(clamping: -2)), by: unhurried(clock))
        try device.scroll(Scroll(vertical: Count(clamping: 3), horizontal: .zero), by: unhurried(clock))
        #expect(device.buttonsDown == [.left])
        try device.releaseAll(by: unhurried(clock))
        try device.move(Move(x: Count(clamping: 1), y: .zero), by: unhurried(clock))
        #expect(device.buttonsDown.isEmpty)
        #expect(pointingReports(fake) == [
            [1, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 10, 0xfe, 0, 0],
            [1, 0, 0, 0, 0, 0, 3, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 1, 0, 0, 0],
        ])
    }

    /// A hold replaces the buttons down: left and right held, then left alone, keeps the
    /// left drag going, and motion after it carries only the left.
    @Test func aHoldReplacesTheButtonsDown() throws {
        let fake = FakeDaemon(handling: daemonWhoseMouseComesUp), clock = ManualClock()
        let device = try mouse(on: fake, clock)
        try device.start(by: unhurried(clock))
        try device.hold([.left, .right], by: unhurried(clock))
        try device.hold([.left], by: unhurried(clock))
        try device.hold([.left], by: unhurried(clock))
        try device.move(Move(x: Count(clamping: 1), y: .zero), by: unhurried(clock))
        try device.hold([], by: unhurried(clock))
        #expect(device.buttonsDown.isEmpty)
        #expect(pointingReports(fake) == [
            [3, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 1, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ])
    }

    /// The record may over-report what the device holds and may never under-report: a
    /// button it has already forgotten is one nothing will lift. Presses are answered and
    /// releases are not, which is the mid-drag timeout this is about.
    @Test func anUnansweredReleaseLeavesTheButtonRecordedAsHeld() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, let payload) = frame else { return }
            let sent = requestSent(payload)
            let releasing = sent.request == DaemonConnection.Request.pointingReset.rawValue
                || (sent.request == DaemonConnection.Request.postPointingInputReport.rawValue && sent.bytes.allSatisfy { $0 == 0 })
            guard !releasing else { return }
            try fake.send(.response(id: id, payload: []))
        }
        let clock = ManualClock()
        let device = try mouse(on: fake, clock)
        try device.down(.right, by: unhurried(clock))
        #expect(try givenUpOn(fake, clock, atRequest: 2) { try device.releaseAll(by: $0) } == silent())
        #expect(device.buttonsDown == [.right])
        #expect(try givenUpOn(fake, clock, atRequest: 3) { try device.reset(by: $0) } == silent())
        #expect(device.buttonsDown == [.right])
    }

    /// A press the driver did not answer may have reached it, so the button is recorded as
    /// one it may hold.
    @Test func aButtonIsRecordedAsMaybeHeldWhenItsReportGoesUnanswered() throws {
        let fake = FakeDaemon { _, _ in }, clock = ManualClock()
        let device = try mouse(on: fake, clock)
        #expect(try givenUpOn(fake, clock, atRequest: 1) { try device.down(.middle, by: $0) } == silent())
        #expect(device.buttonsDown == [.middle])
    }

    @Test func resetAsksTheDaemonToClearTheDeviceAndForgetsWhatWasHeld() throws {
        let fake = FakeDaemon(handling: daemonWhoseMouseComesUp), clock = ManualClock()
        let device = try mouse(on: fake, clock)
        try device.start(by: unhurried(clock))
        try device.down(.left, by: unhurried(clock))
        try device.reset(by: unhurried(clock))
        #expect(device.buttonsDown.isEmpty)
        let sent = fake.requestPayloads.map(requestSent)
        #expect(sent.last?.request == DaemonConnection.Request.pointingReset.rawValue)
        #expect(sent.last?.bytes.isEmpty == true)
    }
}
