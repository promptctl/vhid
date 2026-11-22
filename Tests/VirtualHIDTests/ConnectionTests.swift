import Foundation
import Keystrokes
import Pointing
import OwnThread
import Testing
@testable import VirtualHID

/// What the connection does between requests, which is where a long-lived one spends
/// nearly all of its life. Measured on the daemon: it hangs up on a client that has sent
/// nothing for fifteen seconds, and answering its status pushes does not count as sending.
@Suite(.ownThread, .timeLimit(.minutes(1))) struct ConnectionTests {
    /// A heartbeat goes out on its own, with nobody asking anything. Timed against a short
    /// interval so the test watches for the behaviour rather than sleeping the daemon's
    /// three seconds. [LAW:behavior-not-structure]
    @Test func aHeartbeatGoesOutWhileNothingIsBeingAsked() throws {
        let fake = FakeDaemon()
        let connection = try fake.connection(heartbeatEvery: .milliseconds(20))
        try fake.awaitFrame(.control(.heartbeat, payload: []))
        withExtendedLifetime(connection) {}
    }

    /// A status the daemon pushes while nothing is in flight is recorded and answered: the
    /// reading does not wait for a request to happen inside of.
    @Test func aStatusPushedBetweenRequestsIsRecordedAndAnswered() throws {
        let fake = FakeDaemon()
        let connection = try fake.connection()
        try fake.push([(.keyboardReady, true)])
        #expect(throws: Never.self) { try connection.wait(for: .keyboardReady, within: .seconds(2)) }
        try fake.awaitFrame(.response(id: 10_001, payload: []))
    }

    /// The daemon going away is an event, told once to whoever holds the connection, and
    /// every request after it fails by the same name rather than by a broken pipe on the
    /// next write. [LAW:no-silent-failure]
    @Test func theDaemonHangingUpIsToldOnceAndFailsEveryLaterRequest() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let device = VirtualKeyboard(daemon: try fake.connection(whenLost: lost.record))
        fake.hangUp()
        #expect(try lost.first() == .closed)
        #expect(throws: DaemonError.closed) { try device.down(.leftShift) }
        #expect(throws: DaemonError.closed) { try device.releaseAll() }
        #expect(lost.count == 1)
    }

    /// A write that fails is the same loss as a stream that ends, found by the thread that
    /// asked rather than the one that reads: told once, thrown from the request that found
    /// it, and every later request fails by the same name. [LAW:single-enforcer]
    ///
    /// The write is made to fail by shutting this side's sending half, which makes the
    /// next write fail with EPIPE while the reader goes on reading. Not the daemon's
    /// receiving half: measured, a peer's SHUT_RD leaves this side's writes succeeding on
    /// XNU, so that would test nothing.
    @Test func aWriteThatFailsIsTheLossToldOnceAndThrownFromTheRequestThatFoundIt() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try fake.connection(whenLost: lost.record)
        #expect(shutdown(fake.clientDescriptor, SHUT_WR) == 0)
        let failed = DaemonError.socket("write", EPIPE)
        #expect(throws: failed) { try connection.request(.keyboardInitialize, within: .seconds(2)) }
        #expect(try lost.first() == failed)
        #expect(throws: failed) { try connection.request(.keyboardReset, within: .seconds(2)) }
        #expect(lost.count == 1)
    }

    /// A daemon that stops talking without hanging up - suspended, or wedged - is as gone
    /// as one that closed the stream, and is found out by its silence rather than waited
    /// on forever. [LAW:no-ambient-temporal-coupling] The fake says nothing at all, so the
    /// silence is certain however slowly anything runs.
    @Test func aDaemonThatSaysNothingForThePatienceIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try fake.connection(patience: .milliseconds(100), whenLost: lost.record)
        #expect(try lost.first() == .silent)
        withExtendedLifetime(connection) {}
    }

    /// A daemon that stops mid-frame is the same silence, noticed in the middle of a read
    /// rather than between frames.
    @Test func aDaemonThatStopsMidFrameIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try fake.connection(patience: .milliseconds(100), whenLost: lost.record)
        try fake.sendRaw([0, 0])
        #expect(try lost.first() == .silent)
        withExtendedLifetime(connection) {}
    }

    /// A version mismatch arrives on the frame that answers a request, and that request
    /// fails by its name: the answer does not count, because a driver built for another
    /// protocol did not do what was asked. [LAW:no-silent-failure]
    @Test func anAnswerCarryingAVersionMismatchFailsTheRequestItAnswers() throws {
        let fake = FakeDaemon { frame, daemon in
            if case .request(let id, _) = frame {
                try daemon.send(.response(id: id, payload: [DaemonConnection.Status.driverVersionMismatched.rawValue, 1]))
            }
        }
        let lost = Lost()
        let connection = try fake.connection(whenLost: lost.record)
        #expect(throws: DaemonError.driverVersionMismatched) { try connection.request(.keyboardInitialize, within: .seconds(2)) }
        #expect(try lost.first() == .driverVersionMismatched)
    }

    /// The driver going away under a connection that stays open is the same loss as the
    /// connection ending: told once, with what the daemon took back and its latest word,
    /// and every later report refused by that name with nothing sent. The fake goes on
    /// answering reports throughout, as the daemon does. [LAW:no-silent-failure]
    ///
    /// The frames are the ones pqrs's daemon sent a client on studious (macOS 15.0.1,
    /// package 8.4.0) on 2026-10-01, when the driver extension's process was killed.
    @Test func theDriverGoingAwayUnderAnOpenConnectionIsTheLossAndNoReportIsSentAfterIt() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let daemon = try fake.connection(whenLost: lost.record)
        let keyboard = VirtualKeyboard(daemon: daemon)
        let mouse = VirtualPointing(daemon: daemon)
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try keyboard.start(within: .seconds(2))
        try mouse.start(within: .seconds(2))
        try keyboard.down(.leftShift)
        let sentWhileUp = fake.requestPayloads.count

        try fake.push(Self.said(activated: false, connected: false, keyboard: false, pointing: false))
        let gone = DaemonError.withdrawn(.driverActivated, said: [.driverActivated: false, .driverConnected: false, .driverVersionMismatched: false, .keyboardReady: false, .pointingReady: false])
        #expect(try lost.first() == gone)
        #expect(throws: gone) { try keyboard.releaseAll() }
        #expect(throws: gone) { try mouse.move(by: Move(x: Count(clamping: 1), y: .zero)) }
        #expect(fake.requestPayloads.count == sentWhileUp)
        #expect(lost.count == 1)
        #expect(gone.description == "the driver's daemon said driver activated and then took it back; it last said driver activated: no, driver connected: no, driver version mismatched: no, keyboard ready: no, pointing ready: no")
    }

    /// The driver coming back on the same connection does not bring the lost devices back:
    /// the daemon makes new ones, and the connection that held the old ones stays ended.
    @Test func theDriverComingBackDoesNotReviveTheConnectionThatLostIt() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let keyboard = VirtualKeyboard(daemon: try fake.connection(whenLost: lost.record))
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try keyboard.start(within: .seconds(2))
        try fake.push(Self.said(connected: true, keyboard: false, pointing: true))
        let gone = try lost.first()
        guard case .withdrawn(.keyboardReady, _) = gone else { Issue.record("lost to \(gone)"); return }
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        #expect(throws: gone) { try keyboard.down(.leftShift) }
        #expect(lost.count == 1)
    }

    /// A loss this side declares ends the stream for the daemon while the connection is
    /// still held: the daemon keeps a client's devices, and what is down on them, until
    /// the client goes, and the pointing device here was never taken back.
    @Test func aLossThisSideDeclaresEndsTheStreamForTheDaemon() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let daemon = try fake.connection(whenLost: lost.record)
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try daemon.wait(for: .pointingReady, within: .seconds(2))
        try fake.push(Self.said(connected: true, keyboard: false, pointing: true))
        _ = try lost.first()
        try fake.awaitClientHangUp()
        withExtendedLifetime(daemon) {}
    }

    /// What the daemon says on the way up is not a loss: it answers the first request
    /// before it has connected to the driver, and says each thing as it becomes true.
    /// Nothing is taken back, so the devices come up. The frames are the ones it sent a
    /// client that brought the keyboard up and then the mouse, on studious on 2026-10-01.
    @Test func whatTheDaemonSaysWhileBringingTheDevicesUpIsNotALoss() throws {
        let fake = FakeDaemon { frame, daemon in
            guard case .request(let id, let payload) = frame else { return }
            // The answer carries the first frame's statuses, and each is then pushed; a
            // posted report is answered with none.
            let frames: [[(DaemonConnection.Status, Bool)]] = switch DaemonConnection.Request(rawValue: requestSent(payload).request) {
            case .keyboardInitialize: [Self.said(connected: false, keyboard: false, pointing: false), Self.said(connected: true, keyboard: false, pointing: false), Self.said(connected: true, keyboard: true, pointing: false)]
            case .pointingInitialize: [Self.said(connected: true, keyboard: true, pointing: false), Self.said(connected: true, keyboard: true, pointing: true)]
            default: []
            }
            try daemon.send(.response(id: id, payload: (frames.first ?? []).flatMap { [$0.0.rawValue, $0.1 ? 1 : 0] }))
            try frames.forEach(daemon.push)
        }
        let lost = Lost()
        let daemon = try fake.connection(whenLost: lost.record)
        let keyboard = VirtualKeyboard(daemon: daemon)
        let mouse = VirtualPointing(daemon: daemon)
        try keyboard.start(within: .seconds(2))
        try mouse.start(within: .seconds(2))
        #expect(throws: Never.self) { try keyboard.down(.leftShift) }
        #expect(lost.count == 0)
    }

    /// The five statuses the daemon sends in every frame that carries any.
    private static func said(activated: Bool = true, connected: Bool, keyboard: Bool, pointing: Bool) -> [(DaemonConnection.Status, Bool)] {
        [(.driverActivated, activated), (.driverConnected, connected), (.driverVersionMismatched, false), (.keyboardReady, keyboard), (.pointingReady, pointing)]
    }

    /// An answer to a request nobody waits on any more - it timed out and was forgotten -
    /// is dropped, and the next request is answered as its own.
    @Test func aLateAnswerToAForgottenRequestIsDroppedAndTheNextIsAnswered() throws {
        // Initialize is left unanswered; everything else is answered at once.
        let fake = FakeDaemon { frame, daemon in
            guard case .request(let id, let payload) = frame else { return }
            guard requestSent(payload).request != DaemonConnection.Request.keyboardInitialize.rawValue else { return try daemon.withhold() }
            try daemon.send(.response(id: id, payload: []))
        }
        let connection = try fake.connection()
        #expect(throws: DaemonError.silent) { try connection.request(.keyboardInitialize, within: DaemonConnection.reportLimit) }
        let forgotten = try #require(fake.received.compactMap { if case .request(let id, _) = $0 { id } else { nil } }.first)
        try fake.send(.response(id: forgotten, payload: []))
        #expect(throws: Never.self) { try connection.request(.keyboardReset, within: .seconds(2)) }
    }

    /// A daemon that stops draining its socket without hanging up stalls a write once the
    /// kernel's buffers are full. The write is bounded by the drain, and past it the
    /// request ends in the same loss, rather than blocking the writer and, through the
    /// lock, every waiter, for good. [LAW:no-ambient-temporal-coupling]
    ///
    /// The fake reads one frame and then nothing more, and says nothing either: it cannot
    /// answer, so every request's short limit is one it must miss. The heartbeat and the
    /// silence are put at the hang guard, so the stalled write is the only way the
    /// connection can end. The frames are the largest this side sends, 4100 bytes against
    /// the 8 KB of send space the test sets on the pair: the first is written and misses
    /// its answer, and the second finds the space full part way through and is the loss.
    /// On the real clock: the misses are a daemon that cannot answer, not a race.
    @Test func aWriteThePeerStopsDrainingEndsAsSilenceWithinTheDrain() throws {
        let finished = Gate()
        let fake = FakeDaemon { _, _ in try finished.wait(for: "the test to finish") }
        defer { finished.open() }
        try fake.limitSendSpace(to: 8192)
        let lost = Lost()
        let connection = try DaemonConnection(
            fileDescriptor: fake.clientDescriptor, heartbeatEvery: hangGuard, patience: hangGuard, drain: .milliseconds(100), whenLost: lost.record
        )
        #expect(throws: DaemonError.silent) { try connection.request(.keyboardInitialize, within: .milliseconds(50)) }

        let payload = [UInt8](repeating: 0, count: Frame.largestBody - 12)
        let ended = Gate()
        let thrown = Lost()
        Thread {
            for _ in 0..<16 where lost.count == 0 {
                do { try connection.request(.postKeyboardInputReport, payload, within: .milliseconds(50)) }
                catch let error as DaemonError { thrown.record(error) }
                catch { Issue.record("a request threw \(error), which is not the daemon's") }
            }
            ended.open()
        }.start()
        try ended.wait(for: "the stalled write to end")
        #expect(try lost.first() == .silent)
        #expect(lost.count == 1)
        #expect(thrown.all.allSatisfy { $0 == .silent })
        #expect(thrown.count == 2, "\(thrown.count) requests ended before the connection did, not the one unanswered and the one stalled")
    }

    /// This side hanging up is not the daemon's doing, and is not reported as it. Checked
    /// once the link has let go of the callback, after which it can never be called.
    @Test func hangingUpOurselvesTellsNobody() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let released = Gate()
        do {
            let held = Held(released)
            let connection = try fake.connection(whenLost: { error in withExtendedLifetime(held) { lost.record(error) } })
            withExtendedLifetime(connection) {}
        }
        try released.wait(for: "the connection to let go of its whenLost")
        #expect(lost.count == 0)
    }
}

/// Opens a gate when the last thing holding it lets go.
private final class Held: Sendable {
    private let released: Gate<Bool>
    init(_ released: Gate<Bool>) { self.released = released }
    deinit { released.open() }
}

/// What `whenLost` was told, readable from the test's thread.
private final class Lost: Sendable {
    private let errors = Gate<[DaemonError]>([])

    @Sendable func record(_ error: DaemonError) {
        errors.update { $0.append(error) }
    }

    var all: [DaemonError] { errors.now }

    var count: Int { all.count }

    /// The first error, once there is one.
    func first() throws(Hung) -> DaemonError {
        try errors.wait(for: "the connection to be lost") { $0.first }
    }
}
