import Foundation
import Pointing
import OwnThread
import Testing
import Waiting
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

private func mouse(on fake: FakeDaemon) throws -> VirtualPointing {
    VirtualPointing(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor))
}

private let post = DaemonConnection.Request.postPointingInputReport

/// The pointing reports the device actually put on the wire, in order.
private func pointingReports(_ fake: FakeDaemon) -> [[UInt8]] {
    fake.requestPayloads.map(requestSent).filter { $0.request == DaemonConnection.Request.postPointingInputReport.rawValue }.map(\.bytes)
}

@Suite(.ownThread, .hangGuarded) struct PointingStartupTests {
    /// `pointing_initialize` carries nothing after the request byte, and the wait is for
    /// the pointing device's own readiness: a daemon whose keyboard is ready has said
    /// nothing about its mouse.
    @Test func initializeCarriesNoPayloadAndWaitsForThePointingDevice() throws {
        let fake = FakeDaemon(handling: daemonWhoseMouseComesUp)
        try mouse(on: fake).start(by: guarded())
        let sent = requestSent(fake.requestPayloads[0])
        #expect(sent.version == 7)
        #expect(sent.request == DaemonConnection.Request.pointingInitialize.rawValue)
        #expect(sent.bytes.isEmpty)
    }

    /// The deadline passes once this side has answered the push, so the push was heard.
    @Test func aKeyboardThatIsReadyIsNotAMouseThatIsReady() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, _) = frame else { return }
            try fake.send(.response(id: id, payload: []))
            try fake.push([(.keyboardReady, true)])
        }
        let device = try mouse(on: fake)
        let miss = try missed(once: fake, has: { $0.contains(.response(id: 10_001, payload: [])) }) { try device.start(by: $0) }
        #expect(miss as? DaemonError == .notReady(awaiting: .pointingReady, said: [.keyboardReady: true]))
    }
}

@Suite(.ownThread, .hangGuarded) struct ButtonsDownTests {
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
        let fake = FakeDaemon(handling: daemonWhoseMouseComesUp)
        let device = try mouse(on: fake)
        try device.start(by: guarded())
        try device.down(.left, by: guarded())
        try device.move(Move(x: Count(clamping: 10), y: Count(clamping: -2)), by: guarded())
        try device.scroll(Scroll(vertical: Count(clamping: 3), horizontal: .zero), by: guarded())
        #expect(device.buttonsDown == [.left])
        try device.releaseAll(by: guarded())
        try device.move(Move(x: Count(clamping: 1), y: .zero), by: guarded())
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
        let fake = FakeDaemon(handling: daemonWhoseMouseComesUp)
        let device = try mouse(on: fake)
        try device.start(by: guarded())
        try device.hold([.left, .right], by: guarded())
        try device.hold([.left], by: guarded())
        try device.hold([.left], by: guarded())
        try device.move(Move(x: Count(clamping: 1), y: .zero), by: guarded())
        try device.hold([], by: guarded())
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
        let device = try mouse(on: fake)
        try device.down(.right, by: guarded())
        #expect(try missed(once: fake, has: sent(post, times: 2)) { try device.releaseAll(by: $0) } as? DaemonError == .silent)
        #expect(device.buttonsDown == [.right])
        #expect(try missed(once: fake, has: sent(.pointingReset)) { try device.reset(by: $0) } as? DaemonError == .silent)
        #expect(device.buttonsDown == [.right])
    }

    /// A release that went unanswered is not undone by the move after it: the move is built
    /// from what was asked, so it carries no button, and its answer - the whole of what the
    /// device holds - settles the button up. A move built from what may be held would press
    /// it again.
    @Test func aMoveAfterAnUnansweredReleaseDoesNotPressTheButtonAgain() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, let payload) = frame else { return }
            let sent = requestSent(payload)
            guard !(sent.request == post.rawValue && sent.bytes.allSatisfy { $0 == 0 }) else { return }
            try fake.send(.response(id: id, payload: []))
        }
        let device = try mouse(on: fake)
        try device.down(.right, by: guarded())
        #expect(try missed(once: fake, has: sent(post, times: 2)) { try device.releaseAll(by: $0) } as? DaemonError == .silent)
        try device.move(Move(x: Count(clamping: 1), y: .zero), by: guarded())
        #expect(pointingReports(fake).last == [0, 0, 0, 0, 1, 0, 0, 0])
        #expect(device.buttonsDown.isEmpty)
    }

    @Test func aButtonIsRecordedDownWhenItsReportReachedTheDaemonUnanswered() throws {
        let fake = FakeDaemon { _, _ in }
        let device = try mouse(on: fake)
        #expect(try missed(once: fake, has: sent(post)) { try device.down(.middle, by: $0) } as? DaemonError == .silent)
        #expect(device.buttonsDown == [.middle])
    }

    /// A report that was never sent changed nothing on the driver, so it changes nothing in
    /// the record, and no later report carries its button.
    @Test func aReportThatWasNotSentLeavesTheButtonsAsTheyWere() throws {
        let fake = FakeDaemon(handling: daemonWhoseMouseComesUp)
        let device = try mouse(on: fake)
        try device.start(by: guarded())
        #expect(throws: DaemonError.unsent) { try device.down(.middle, by: spent()) }
        #expect(device.buttonsDown.isEmpty)
        try device.move(Move(x: Count(clamping: 1), y: .zero), by: guarded())
        #expect(pointingReports(fake) == [[0, 0, 0, 0, 1, 0, 0, 0]])
    }

    @Test func resetAsksTheDaemonToClearTheDeviceAndForgetsWhatWasHeld() throws {
        let fake = FakeDaemon(handling: daemonWhoseMouseComesUp)
        let device = try mouse(on: fake)
        try device.start(by: guarded())
        try device.down(.left, by: guarded())
        try device.reset(by: guarded())
        #expect(device.buttonsDown.isEmpty)
        let sent = fake.requestPayloads.map(requestSent)
        #expect(sent.last?.request == DaemonConnection.Request.pointingReset.rawValue)
        #expect(sent.last?.bytes.isEmpty == true)
    }
}
