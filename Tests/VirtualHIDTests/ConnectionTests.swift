import Foundation
import Keystrokes
import Pointing
import OwnThread
import TestClock
import Testing
import Time
@testable import VirtualHID

/// What the connection does between requests, which is where a long-lived one spends
/// nearly all of its life. Measured on the daemon: it hangs up on a client that has sent
/// nothing for fifteen seconds, and answering its status pushes does not count as sending.
///
/// Every wait is on a test clock, which moves only when a test moves it: a heartbeat goes
/// out, a silence is noticed and a request is given up on exactly when the test says, and
/// never for how slowly the Mac ran the test.
@Suite(.ownThread) struct ConnectionTests {
    /// A deadline nothing in the test reaches, on a clock nothing moves.
    static func unhurried(_ clock: ManualClock) -> Deadline { .within(.seconds(2), on: Clock(clock)) }

    /// A heartbeat goes out on its own, with nobody asking anything, once its interval has
    /// passed. [LAW:behavior-not-structure]
    @Test func aHeartbeatGoesOutWhileNothingIsBeingAsked() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), heartbeatEvery: .milliseconds(20))
        clock.advance(by: .milliseconds(20))
        #expect(fake.awaitFrame(.control(.heartbeat, payload: [])))
        withExtendedLifetime(connection) {}
    }

    /// A status the daemon pushes while nothing is in flight is recorded and answered: the
    /// reading does not wait for a request to happen inside of.
    @Test func aStatusPushedBetweenRequestsIsRecordedAndAnswered() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock))
        let id = try fake.push([(.keyboardReady, true)])
        #expect(throws: Never.self) { try connection.wait(for: .keyboardReady, by: Self.unhurried(clock)) }
        #expect(fake.awaitFrame(.response(id: id, payload: [])))
    }

    /// The daemon going away is an event, told once to whoever holds the connection, and
    /// every request after it is refused unsent by the same name rather than by a broken
    /// pipe on the next write. [LAW:no-silent-failure]
    @Test func theDaemonHangingUpIsToldOnceAndRefusesEveryLaterRequestUnsent() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let lost = Lost()
        let device = VirtualKeyboard(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), whenLost: lost.record))
        fake.hangUp()
        #expect(lost.await() == .closed)
        let refused = Unanswered(reach: .unsent, cause: .connection(.closed))
        #expect(throws: refused) { try device.down(.leftShift, by: Self.unhurried(clock)) }
        #expect(throws: refused) { try device.releaseAll(by: Self.unhurried(clock)) }
        #expect(refused.description == "the driver's daemon closed the connection, and the request was not sent")
        #expect(lost.count == 1)
    }

    /// A write that fails is the same loss as a stream that ends, found by the thread that
    /// writes rather than the one that reads: told once, thrown from the request it was
    /// writing as one the driver may have, and every later request refused unsent by the
    /// same name. [LAW:single-enforcer]
    ///
    /// The write is made to fail by shutting this side's sending half, which makes the
    /// next write fail with EPIPE while the reader goes on reading. Not the daemon's
    /// receiving half: measured, a peer's SHUT_RD leaves this side's writes succeeding on
    /// XNU, so that would test nothing.
    @Test func aWriteThatFailsIsTheLossToldOnceAndThrownFromTheRequestBeingWritten() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), whenLost: lost.record)
        #expect(shutdown(fake.clientDescriptor, SHUT_WR) == 0)
        let failed = DaemonError.socket("write", EPIPE)
        #expect(throws: Unanswered(reach: .writing, cause: .connection(failed))) { try connection.request(.keyboardInitialize, by: Self.unhurried(clock)) }
        #expect(lost.await() == failed)
        #expect(throws: Unanswered(reach: .unsent, cause: .connection(failed))) { try connection.request(.keyboardReset, by: Self.unhurried(clock)) }
        #expect(lost.count == 1)
    }

    /// A daemon that stops talking without hanging up - suspended, or wedged - is as gone
    /// as one that closed the stream, and is found out by its silence over the patience
    /// rather than waited on forever. [LAW:no-ambient-temporal-coupling]
    @Test func aDaemonThatSaysNothingForThePatienceIsLost() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), patience: .milliseconds(100), whenLost: lost.record)
        clock.advance(by: .milliseconds(100))
        #expect(lost.await() == .silent)
        withExtendedLifetime(connection) {}
    }

    /// A daemon that stops mid-frame is the same silence, noticed in the middle of a read,
    /// a patience after the last byte it sent rather than after the frame began.
    @Test func aDaemonThatStopsMidFrameIsLostAPatienceAfterItsLastByte() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let lost = Lost()
        let began = clock.now
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), heartbeatEvery: .seconds(60), patience: .milliseconds(100), whenLost: lost.record)
        clock.advance(by: .milliseconds(50))
        try fake.sendRaw([0, 0])
        // The wait for the rest is a patience after the bytes came, and moves with each
        // byte that comes: counted from the frame's first byte, it would stay at 150.
        clock.awaitBlocked(until: began.advanced(by: .milliseconds(150)))
        clock.advance(by: .milliseconds(50))
        try fake.sendRaw([0])
        clock.awaitBlocked(until: began.advanced(by: .milliseconds(200)))
        clock.advance(by: .milliseconds(100))
        #expect(lost.await() == .silent)
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
        let clock = ManualClock(), lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), whenLost: lost.record)
        let failed = try #require(#expect(throws: Unanswered.self) { try connection.request(.keyboardInitialize, by: Self.unhurried(clock)) })
        #expect(failed.cause == .connection(.driverVersionMismatched))
        #expect(failed.mayHaveReachedTheDriver)
        #expect(lost.await() == .driverVersionMismatched)
    }

    /// The driver going away under a connection that stays open is the same loss as the
    /// connection ending: told once, with what the daemon took back and its latest word,
    /// and every later report refused by that name with nothing sent. The fake goes on
    /// answering reports throughout, as the daemon does. [LAW:no-silent-failure]
    ///
    /// The frames are the ones pqrs's daemon sent a client on studious (macOS 15.0.1,
    /// package 8.4.0) on 2026-10-01, when the driver extension's process was killed.
    @Test func theDriverGoingAwayUnderAnOpenConnectionIsTheLossAndNoReportIsSentAfterIt() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let lost = Lost()
        let daemon = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), whenLost: lost.record)
        let keyboard = VirtualKeyboard(daemon: daemon)
        let mouse = VirtualPointing(daemon: daemon)
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try keyboard.start(by: Self.unhurried(clock))
        try mouse.start(by: Self.unhurried(clock))
        try keyboard.down(.leftShift, by: Self.unhurried(clock))
        let sentWhileUp = fake.requestPayloads.count

        try fake.push(Self.said(activated: false, connected: false, keyboard: false, pointing: false))
        let gone = DaemonError.withdrawn(.driverActivated, said: [.driverActivated: false, .driverConnected: false, .driverVersionMismatched: false, .keyboardReady: false, .pointingReady: false])
        #expect(lost.await() == gone)
        #expect(throws: Unanswered(reach: .unsent, cause: .connection(gone))) { try keyboard.releaseAll(by: Self.unhurried(clock)) }
        #expect(throws: Unanswered(reach: .unsent, cause: .connection(gone))) { try mouse.move(Move(x: Count(clamping: 1), y: .zero), by: Self.unhurried(clock)) }
        #expect(fake.requestPayloads.count == sentWhileUp)
        #expect(lost.count == 1)
        #expect(gone.description == "the driver's daemon said driver activated and then took it back; it last said driver activated: no, driver connected: no, driver version mismatched: no, keyboard ready: no, pointing ready: no")
    }

    /// The driver coming back on the same connection does not bring the lost devices back:
    /// the daemon makes new ones, and the connection that held the old ones stays ended.
    @Test func theDriverComingBackDoesNotReviveTheConnectionThatLostIt() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let lost = Lost()
        let keyboard = VirtualKeyboard(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), whenLost: lost.record))
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try keyboard.start(by: Self.unhurried(clock))
        try fake.push(Self.said(connected: true, keyboard: false, pointing: true))
        let gone = try #require(lost.await())
        guard case .withdrawn(.keyboardReady, _) = gone else { Issue.record("lost to \(gone)"); return }
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        #expect(throws: Unanswered(reach: .unsent, cause: .connection(gone))) { try keyboard.down(.leftShift, by: Self.unhurried(clock)) }
        #expect(lost.count == 1)
    }

    /// A loss this side declares ends the stream for the daemon while the connection is
    /// still held: the daemon keeps a client's devices, and what is down on them, until
    /// the client goes, and the pointing device here was never taken back.
    @Test func aLossThisSideDeclaresEndsTheStreamForTheDaemon() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let lost = Lost()
        let daemon = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), whenLost: lost.record)
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try daemon.wait(for: .pointingReady, by: Self.unhurried(clock))
        try fake.push(Self.said(connected: true, keyboard: false, pointing: true))
        #expect(lost.await() != nil)
        #expect(fake.awaitClientHangUp())
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
            try frames.forEach { try daemon.push($0) }
        }
        let clock = ManualClock(), lost = Lost()
        let daemon = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), whenLost: lost.record)
        let keyboard = VirtualKeyboard(daemon: daemon)
        let mouse = VirtualPointing(daemon: daemon)
        try keyboard.start(by: Self.unhurried(clock))
        try mouse.start(by: Self.unhurried(clock))
        #expect(throws: Never.self) { try keyboard.down(.leftShift, by: Self.unhurried(clock)) }
        #expect(lost.count == 0)
    }

    /// The five statuses the daemon sends in every frame that carries any.
    private static func said(activated: Bool = true, connected: Bool, keyboard: Bool, pointing: Bool) -> [(DaemonConnection.Status, Bool)] {
        [(.driverActivated, activated), (.driverConnected, connected), (.driverVersionMismatched, false), (.keyboardReady, keyboard), (.pointingReady, pointing)]
    }

    /// An answer to a request nobody waits on any more - given up on at its deadline and
    /// forgotten - is dropped, and the next request is answered as its own.
    @Test func aLateAnswerToAForgottenRequestIsDroppedAndTheNextIsAnswered() throws {
        // Initialize is left unanswered; everything else is answered at once.
        let fake = FakeDaemon { frame, daemon in
            guard case .request(let id, let payload) = frame, requestSent(payload).request != DaemonConnection.Request.keyboardInitialize.rawValue else { return }
            try daemon.send(.response(id: id, payload: []))
        }
        let clock = ManualClock()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock))
        #expect(try givenUpOn(fake, clock, atRequest: 1) { try connection.request(.keyboardInitialize, by: $0) } == silent())
        let forgotten = try #require(fake.received.compactMap { if case .request(let id, _) = $0 { id } else { nil } }.first)
        try fake.send(.response(id: forgotten, payload: []))
        #expect(throws: Never.self) { try connection.request(.keyboardReset, by: Self.unhurried(clock)) }
    }

    /// A request whose deadline had passed when it was asked writes nothing.
    @Test func aRequestAskedAfterItsDeadlineWritesNothing() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock))
        let late = Deadline.within(.seconds(1), on: Clock(clock))
        clock.advance(by: .seconds(1))
        #expect(throws: Unanswered(reach: .unsent, cause: .deadline(Deadline.Exceeded(limit: .seconds(1), spent: .seconds(1))))) { try connection.request(.keyboardReset, by: late) }
        try fake.settle()
        #expect(fake.requestPayloads.isEmpty)
    }

    /// A daemon that stops draining its socket without hanging up stalls a write once the
    /// kernel's buffers are full. Nobody waits on the stall past their own deadline: the
    /// request written whole ends silent, the one being written ends stalled - the rest is
    /// still going, so the driver may yet have it - and the one behind them ends unsent and
    /// is never written. Past the patience the stall is the loss, as silence on the
    /// reading side is. [LAW:no-ambient-temporal-coupling]
    ///
    /// The frames are the largest this side sends, 4100 bytes against the 8 KB of send
    /// space the test sets on the pair, after a first request the fake reads before it
    /// stops reading: the first large one fits, and the second finds the space full part
    /// way through. Which wait has been reached is read off the test clock: the reader's,
    /// then each asker's, then the stalled writer's.
    @Test func aWriteThePeerStopsDrainingHoldsNoAskerPastItsDeadlineAndEndsAsSilenceAtThePatience() throws {
        let stopped = Gate()
        let fake = FakeDaemon { _, _ in stopped.arrive() }
        defer { stopped.open() }
        try fake.limitSendSpace(to: 8192)
        let clock = ManualClock(), lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), heartbeatEvery: .seconds(60), patience: .seconds(1), whenLost: lost.record)
        let first = Future { try connection.request(.keyboardInitialize, by: .within(.seconds(10), on: Clock(clock))) }
        stopped.arrived.wait("the fake to read the first request and stop")
        clock.awaitBlocked(2)

        let largest = [UInt8](repeating: 0, count: Frame.largestBody - 12)
        func asking() -> Future<Instant> {
            Future { try connection.request(.postKeyboardInputReport, largest, by: .within(.milliseconds(50), on: Clock(clock))) }
        }
        let fits = asking()
        clock.awaitBlocked(3)
        let stalls = asking()
        // Its asker, and the writer waiting for room.
        clock.awaitBlocked(5)
        let behind = asking()
        clock.awaitBlocked(6)

        clock.advance(by: .milliseconds(50))
        let exceeded = Deadline.Exceeded(limit: .milliseconds(50), spent: .milliseconds(50))
        #expect(throws: Unanswered(reach: .written, cause: .deadline(exceeded))) { try fits.get() }
        #expect(throws: Unanswered(reach: .writing, cause: .deadline(exceeded))) { try stalls.get() }
        #expect(throws: Unanswered(reach: .unsent, cause: .deadline(exceeded))) { try behind.get() }
        #expect(lost.count == 0)

        clock.advance(by: .seconds(1))
        #expect(lost.await() == .silent)
        #expect(throws: Unanswered(reach: .written, cause: .connection(.silent))) { try first.get() }
        #expect(throws: Unanswered(reach: .unsent, cause: .connection(.silent))) { try connection.request(.keyboardReset, by: Self.unhurried(clock)) }
        #expect(lost.count == 1)
    }

    /// This side hanging up is not the daemon's doing, and is not reported as it: by the
    /// time the reading thread has ended, nobody was told.
    @Test func hangingUpOurselvesTellsNobody() throws {
        let fake = FakeDaemon(), clock = ManualClock()
        let lost = Lost(), ended = Latch()
        do {
            let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, clock: Clock(clock), whenLost: lost.record, readingEnded: ended.open)
            withExtendedLifetime(connection) {}
        }
        try #require(ended.wait("the reading thread to end"))
        #expect(lost.count == 0)
    }
}

/// What `whenLost` was told, readable from the test's thread.
private final class Lost: Sendable {
    private let errors = Monitor<[DaemonError]>([])

    @Sendable func record(_ error: DaemonError) {
        errors.withLock { $0.append(error) }
    }

    var count: Int { errors.current.count }

    /// The first error, waited for.
    func await(sourceLocation: SourceLocation = #_sourceLocation) -> DaemonError? {
        errors.wait("the connection to be lost", until: { !$0.isEmpty }, sourceLocation: sourceLocation)
        return errors.current.first
    }
}
