import Foundation
import Keystrokes
import Pointing
import Testing
@testable import VirtualHID

/// What the connection does between requests, which is where a long-lived one spends
/// nearly all of its life. Measured on the daemon: it hangs up on a client that has sent
/// nothing for fifteen seconds, and answering its status pushes does not count as sending.
@Suite struct ConnectionTests {
    /// A heartbeat goes out on its own, with nobody asking anything. Timed against a short
    /// interval so the test watches for the behaviour rather than sleeping the daemon's
    /// three seconds. [LAW:behavior-not-structure]
    @Test func aHeartbeatGoesOutWhileNothingIsBeingAsked() throws {
        let fake = FakeDaemon()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, heartbeatEvery: .milliseconds(20))
        #expect(fake.awaitFrame(.control(.heartbeat, payload: [])))
        withExtendedLifetime(connection) {}
    }

    /// A status the daemon pushes while nothing is in flight is recorded and answered: the
    /// reading does not wait for a request to happen inside of.
    @Test func aStatusPushedBetweenRequestsIsRecordedAndAnswered() throws {
        let fake = FakeDaemon()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor)
        try fake.push([(.keyboardReady, true)])
        #expect(throws: Never.self) { try connection.wait(for: .keyboardReady, by: .now + .seconds(2)) }
        #expect(fake.awaitFrame(.response(id: 10_001, payload: [])))
    }

    /// The daemon going away is an event, told once to whoever holds the connection, and
    /// every request after it fails by the same name rather than by a broken pipe on the
    /// next write. [LAW:no-silent-failure]
    @Test func theDaemonHangingUpIsToldOnceAndFailsEveryLaterRequest() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let device = VirtualKeyboard(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record), reportTimeout: .seconds(2))
        fake.hangUp()
        #expect(lost.await() == .closed)
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
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        #expect(shutdown(fake.clientDescriptor, SHUT_WR) == 0)
        let failed = DaemonError.socket("write", EPIPE)
        #expect(throws: failed) { try connection.request(.keyboardInitialize, by: .now + .seconds(2)) }
        #expect(lost.await() == failed)
        #expect(throws: failed) { try connection.request(.keyboardReset, by: .now + .seconds(2)) }
        #expect(lost.count == 1)
    }

    /// A daemon that stops talking without hanging up - suspended, or wedged - is as gone
    /// as one that closed the stream, and is found out by its silence rather than waited
    /// on forever. [LAW:no-ambient-temporal-coupling]
    @Test func aDaemonThatSaysNothingForThePatienceIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, patience: .milliseconds(100), whenLost: lost.record)
        #expect(lost.await() == .silent)
        withExtendedLifetime(connection) {}
    }

    /// A daemon that stops mid-frame is the same silence, noticed in the middle of a read
    /// rather than between frames.
    @Test func aDaemonThatStopsMidFrameIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, patience: .milliseconds(100), whenLost: lost.record)
        try fake.sendRaw([0, 0])
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
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        #expect(throws: DaemonError.driverVersionMismatched) { try connection.request(.keyboardInitialize, by: .now + .seconds(2)) }
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
        let fake = FakeDaemon()
        let lost = Lost()
        let daemon = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        let keyboard = VirtualKeyboard(daemon: daemon, reportTimeout: .seconds(2))
        let mouse = VirtualPointing(daemon: daemon, reportTimeout: .seconds(2))
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try keyboard.start(within: .seconds(2))
        try mouse.start(within: .seconds(2))
        try keyboard.down(.leftShift)
        let sentWhileUp = fake.requestPayloads.count

        try fake.push(Self.said(activated: false, connected: false, keyboard: false, pointing: false))
        let gone = DaemonError.withdrawn(.driverActivated, said: [.driverActivated: false, .driverConnected: false, .driverVersionMismatched: false, .keyboardReady: false, .pointingReady: false])
        #expect(lost.await() == gone)
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
        let keyboard = VirtualKeyboard(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record), reportTimeout: .seconds(2))
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try keyboard.start(within: .seconds(2))
        try fake.push(Self.said(connected: true, keyboard: false, pointing: true))
        let gone = try #require(lost.await())
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
        let daemon = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try daemon.wait(for: .pointingReady, by: .now + .seconds(2))
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
            try frames.forEach(daemon.push)
        }
        let lost = Lost()
        let daemon = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        let keyboard = VirtualKeyboard(daemon: daemon, reportTimeout: .seconds(2))
        let mouse = VirtualPointing(daemon: daemon, reportTimeout: .seconds(2))
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
            guard case .request(let id, let payload) = frame, requestSent(payload).request != DaemonConnection.Request.keyboardInitialize.rawValue else { return }
            try daemon.send(.response(id: id, payload: []))
        }
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor)
        #expect(throws: DaemonError.silent) { try connection.request(.keyboardInitialize, by: .now + .milliseconds(50)) }
        let forgotten = try #require(fake.received.compactMap { if case .request(let id, _) = $0 { id } else { nil } }.first)
        try fake.send(.response(id: forgotten, payload: []))
        #expect(throws: Never.self) { try connection.request(.keyboardReset, by: .now + .seconds(2)) }
    }

    /// A daemon that stops draining its socket without hanging up - and keeps talking, so
    /// its silence never shows on the reading side - stalls a write once the kernel's
    /// buffers are full. The write is bounded by the patience like a read, and past it the
    /// request ends in the same loss, rather than blocking the writer and, through the
    /// lock, every waiter, for good. [LAW:no-ambient-temporal-coupling]
    ///
    /// The frames are the largest this side sends, 4100 bytes against the 8 KB of send space
    /// the test sets on the pair: the first is written and times out unanswered, and the
    /// second finds the space full part way through and is the loss.
    ///
    /// The patience is fifty heartbeats long. The same patience ends a quiet read, so a
    /// shorter one lets a runner that stalls the fake's thread end the connection on the
    /// reading side before any write has stalled, one way to lose after a single request.
    @Test func aWriteThePeerStopsDrainingEndsAsSilenceWithinThePatience() throws {
        // Reads one frame, then talks without listening: a heartbeat every 20 ms until the
        // client hangs up, and not one more read.
        let fake = FakeDaemon { _, daemon in
            while (try? daemon.send(.control(.heartbeat, payload: []))) != nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        try fake.limitSendSpace(to: 8192)
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, patience: .seconds(1), whenLost: lost.record)
        #expect(throws: DaemonError.silent) { try connection.request(.keyboardInitialize, by: .now + .milliseconds(50)) }

        let payload = [UInt8](repeating: 0, count: Frame.largestBody - 12)
        let ended = DispatchSemaphore(value: 0)
        let thrown = Lost()
        Thread {
            for _ in 0..<16 where lost.count == 0 {
                do { try connection.request(.postKeyboardInputReport, payload, by: .now + .milliseconds(50)) }
                catch let error as DaemonError { thrown.record(error) }
                catch { Issue.record("a request threw \(error), which is not the daemon's") }
            }
            ended.signal()
        }.start()
        #expect(ended.wait(timeout: .now() + .seconds(4)) == .success, "the stalled write did not end within 4 s")
        #expect(lost.await(within: .zero) == .silent)
        #expect(lost.count == 1)
        #expect(thrown.all.allSatisfy { $0 == .silent })
        #expect(thrown.count == 2, "\(thrown.count) requests ended before the connection did, not the one unanswered and the one stalled")
    }

    /// This side hanging up is not the daemon's doing, and is not reported as it.
    @Test func hangingUpOurselvesTellsNobody() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        do {
            let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
            withExtendedLifetime(connection) {}
        }
        // The fake's thread ends on the client's end of stream, which is the same event
        // the callback would fire on; once it has ended, the callback has had its chance.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(lost.count == 0)
    }
}

/// What `whenLost` was told, readable from the test's thread.
private final class Lost: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [DaemonError] = []

    @Sendable func record(_ error: DaemonError) {
        lock.lock(); errors.append(error); lock.unlock()
    }

    var all: [DaemonError] {
        lock.lock(); defer { lock.unlock() }
        return errors
    }

    var count: Int { all.count }

    /// The first error, waited for within `limit`; a limit of zero reads what is there.
    func await(within limit: Duration = .seconds(2)) -> DaemonError? {
        let deadline = ContinuousClock.now + limit
        repeat {
            lock.lock(); let first = errors.first; lock.unlock()
            if let first { return first }
            Thread.sleep(forTimeInterval: 0.002)
        } while ContinuousClock.now < deadline
        return nil
    }
}
