import Foundation
import Keystrokes
import Pointing
import OwnThread
import TestClock
import Testing
import Timeline
import Waiting
@testable import VirtualHID

/// What the connection does between requests, which is where a long-lived one spends
/// nearly all of its life. Measured on the daemon: it hangs up on a client that has sent
/// nothing for fifteen seconds, and answering its status pushes does not count as sending.
@Suite(.ownThread, .hangGuarded) struct ConnectionTests {
    /// A heartbeat goes out on its own, with nobody asking anything. Timed against a short
    /// interval so the test watches for the behaviour rather than sleeping the daemon's
    /// three seconds. [LAW:behavior-not-structure]
    @Test func aHeartbeatGoesOutWhileNothingIsBeingAsked() throws {
        let fake = FakeDaemon()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, heartbeatEvery: .milliseconds(20))
        try fake.awaitFrame(.control(.heartbeat, payload: []))
        withExtendedLifetime(connection) {}
    }

    /// A status the daemon pushes while nothing is in flight is recorded and answered: the
    /// reading does not wait for a request to happen inside of.
    @Test func aStatusPushedBetweenRequestsIsRecordedAndAnswered() throws {
        let fake = FakeDaemon()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor)
        try fake.push([(.keyboardReady, true)])
        #expect(throws: Never.self) { try connection.wait(for: .keyboardReady, by: guarded()) }
        try fake.awaitFrame(.response(id: 10_001, payload: []))
    }

    /// The daemon going away is an event, told once to whoever holds the connection, and
    /// every request after it fails by the same name rather than by a broken pipe on the
    /// next write. [LAW:no-silent-failure]
    @Test func theDaemonHangingUpIsToldOnceAndFailsEveryLaterRequest() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let device = VirtualKeyboard(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record))
        fake.hangUp()
        #expect(try lost.first() == .closed)
        #expect(throws: DaemonError.closed) { try device.down(.leftShift, by: guarded()) }
        #expect(throws: DaemonError.closed) { try device.releaseAll(by: guarded()) }
        #expect(lost.count == 1)
    }

    /// A write that fails is the same loss as a stream that ends, found by the thread that
    /// writes rather than the one that reads: told once, thrown from the request whose
    /// write found it, and every later request is refused by the same name with nothing
    /// sent. [LAW:single-enforcer]
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
        #expect(throws: DaemonConnection.Unanswered(reason: failed, mayHaveReached: true)) { try connection.request(.keyboardInitialize, by: guarded()) }
        #expect(try lost.first() == failed)
        #expect(throws: DaemonConnection.Unanswered(reason: failed, mayHaveReached: false)) { try connection.request(.keyboardReset, by: guarded()) }
        #expect(lost.count == 1)
    }

    /// A daemon that stops talking without hanging up - suspended, or wedged - is as gone
    /// as one that closed the stream, and is found out by its silence rather than waited
    /// on forever. [LAW:no-ambient-temporal-coupling]
    @Test func aDaemonThatSaysNothingForThePatienceIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, patience: .milliseconds(100), whenLost: lost.record)
        #expect(try lost.first() == .silent)
        withExtendedLifetime(connection) {}
    }

    /// A daemon that stops mid-frame is the same silence, noticed in the middle of a read
    /// rather than between frames.
    @Test func aDaemonThatStopsMidFrameIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, patience: .milliseconds(100), whenLost: lost.record)
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
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        #expect(throws: DaemonConnection.Unanswered(reason: .driverVersionMismatched, mayHaveReached: true)) { try connection.request(.keyboardInitialize, by: guarded()) }
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
        let daemon = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        let keyboard = VirtualKeyboard(daemon: daemon)
        let mouse = VirtualPointing(daemon: daemon)
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try keyboard.start(by: guarded())
        try mouse.start(by: guarded())
        try keyboard.down(.leftShift, by: guarded())
        let sentWhileUp = fake.requestPayloads.count

        try fake.push(Self.said(activated: false, connected: false, keyboard: false, pointing: false))
        let gone = DaemonError.withdrawn(.driverActivated, said: [.driverActivated: false, .driverConnected: false, .driverVersionMismatched: false, .keyboardReady: false, .pointingReady: false])
        #expect(try lost.first() == gone)
        #expect(throws: gone) { try keyboard.releaseAll(by: guarded()) }
        #expect(throws: gone) { try mouse.move(Move(x: Count(clamping: 1), y: .zero), by: guarded()) }
        #expect(fake.requestPayloads.count == sentWhileUp)
        #expect(lost.count == 1)
        #expect(gone.description == "the driver's daemon said driver activated and then took it back; it last said driver activated: no, driver connected: no, driver version mismatched: no, keyboard ready: no, pointing ready: no")
    }

    /// The driver coming back on the same connection does not bring the lost devices back:
    /// the daemon makes new ones, and the connection that held the old ones stays ended.
    @Test func theDriverComingBackDoesNotReviveTheConnectionThatLostIt() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let keyboard = VirtualKeyboard(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record))
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        try keyboard.start(by: guarded())
        try fake.push(Self.said(connected: true, keyboard: false, pointing: true))
        let gone = try lost.first()
        guard case .withdrawn(.keyboardReady, _) = gone else { Issue.record("lost to \(gone)"); return }
        try fake.push(Self.said(connected: true, keyboard: true, pointing: true))
        #expect(throws: gone) { try keyboard.down(.leftShift, by: guarded()) }
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
        try daemon.wait(for: .pointingReady, by: guarded())
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
        let daemon = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        let keyboard = VirtualKeyboard(daemon: daemon)
        let mouse = VirtualPointing(daemon: daemon)
        try keyboard.start(by: guarded())
        try mouse.start(by: guarded())
        #expect(throws: Never.self) { try keyboard.down(.leftShift, by: guarded()) }
        #expect(lost.count == 0)
    }

    /// The five statuses the daemon sends in every frame that carries any.
    private static func said(activated: Bool = true, connected: Bool, keyboard: Bool, pointing: Bool) -> [(DaemonConnection.Status, Bool)] {
        [(.driverActivated, activated), (.driverConnected, connected), (.driverVersionMismatched, false), (.keyboardReady, keyboard), (.pointingReady, pointing)]
    }

    /// An answer to a request nobody waits on any more - it was missed and forgotten - is
    /// dropped, and the next request is answered as its own. The missed one was written
    /// and not answered, so it is the daemon's silence and may have reached it.
    @Test func aLateAnswerToAForgottenRequestIsDroppedAndTheNextIsAnswered() throws {
        // Initialize is left unanswered; everything else is answered at once.
        let fake = FakeDaemon { frame, daemon in
            guard case .request(let id, let payload) = frame, requestSent(payload).request != DaemonConnection.Request.keyboardInitialize.rawValue else { return }
            try daemon.send(.response(id: id, payload: []))
        }
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor)
        let miss = try missed(once: fake, has: sent(.keyboardInitialize)) { _ = try connection.request(.keyboardInitialize, by: $0) }
        #expect(miss as? DaemonConnection.Unanswered == DaemonConnection.Unanswered(reason: .silent, mayHaveReached: true))
        let forgotten = try #require(fake.received.compactMap { if case .request(let id, _) = $0 { id } else { nil } }.first)
        try fake.send(.response(id: forgotten, payload: []))
        #expect(throws: Never.self) { try connection.request(.keyboardReset, by: guarded()) }
    }

    /// A request the daemon stops taking part way through is told apart from one it never
    /// got: at its deadline the one being written is a stalled write that may have reached
    /// the daemon, and the report queued behind it is not sent at all, and the keyboard's
    /// record of what it holds is as it was. [LAW:no-silent-failure]
    ///
    /// The far end is a bare socket that takes one byte and no more, against a send space
    /// smaller than the frame: the first request is then being written, and can neither be
    /// finished nor taken back, until its deadline - on a clock this test moves - passes.
    @Test func aRequestBeingWrittenAtItsDeadlineHasStalledAndOneBehindItIsNotSent() throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[1]) }
        var space: Int32 = 2048
        for end in pair { try #require(setsockopt(end, SOL_SOCKET, SO_SNDBUF, &space, socklen_t(MemoryLayout<Int32>.size)) == 0) }
        let connection = try DaemonConnection(fileDescriptor: pair[0])
        let keyboard = VirtualKeyboard(daemon: connection)
        let clock = ManualClock()
        let deadline = Timeline(clock).deadline(within: .milliseconds(100))
        let ended = Latch<[String: any Error]>([:])
        let payload = [UInt8](repeating: 0, count: Frame.largestBody - 12)
        Thread.detachNewThread {
            do { try connection.request(.postKeyboardInputReport, payload, by: deadline) } catch { ended.update { $0["written"] = error } }
        }
        var first: UInt8 = 0
        try #require(read(pair[1], &first, 1) == 1)
        Thread.detachNewThread {
            do { try keyboard.down(.leftShift, by: deadline) } catch { ended.update { $0["behind"] = error } }
        }
        clock.advance(by: .milliseconds(100))
        let errors = try ended.wait(for: "both requests to end") { $0.count == 2 ? $0 : nil }
        #expect(errors["written"] as? DaemonConnection.Unanswered == DaemonConnection.Unanswered(reason: .stalled, mayHaveReached: true))
        #expect(errors["behind"] as? DaemonError == .unsent)
        #expect(keyboard.keysDown.isEmpty)
    }

    /// A daemon that stops draining its socket without hanging up - and keeps talking, so
    /// its silence never shows on the reading side - stalls the writer once the kernel's
    /// buffers are full. The write is bounded by the patience like a read, and past it the
    /// connection ends in the same loss, which ends every request on it, rather than
    /// holding them for good. [LAW:no-ambient-temporal-coupling]
    ///
    /// Four of the largest frames this side sends, 4100 bytes each against the 8 KB of
    /// send space the test sets on the pair, so the writer is stalled whichever goes first,
    /// and each request's own deadline is the guard: only the loss can end them.
    @Test func aWriteThePeerStopsDrainingEndsTheConnectionAsSilenceAtThePatience() throws {
        // Reads one frame, then talks without listening: a heartbeat every 20 ms until the
        // client hangs up, and not one more read. The pace is the fake's chatter, which
        // keeps the reader from finding it silent; on a runner slow enough to miss it, the
        // reader finds the same silence the writer would.
        let fake = FakeDaemon { _, daemon in
            while (try? daemon.send(.control(.heartbeat, payload: []))) != nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        try fake.limitSendSpace(to: 8192)
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, patience: .seconds(1), whenLost: lost.record)
        let payload = [UInt8](repeating: 0, count: Frame.largestBody - 12)
        let ended = Latch<[DaemonError]>([])
        for _ in 0..<4 {
            Thread.detachNewThread {
                do throws(DaemonConnection.Unanswered) { try connection.request(.postKeyboardInputReport, payload, by: guarded()) } catch { ended.update { $0.append(error.reason) } }
            }
        }
        let reasons = try ended.wait(for: "every request to end") { $0.count == 4 ? $0 : nil }
        #expect(reasons.allSatisfy { $0 == .silent })
        #expect(try lost.first() == .silent)
        #expect(lost.count == 1)
    }

    /// This side hanging up is not the daemon's doing, and is not reported as it. The
    /// connection lets go of what it was told to call only once both its threads have
    /// ended, so the release is the proof that nothing is left to call it.
    @Test func hangingUpOurselvesTellsNobody() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let released = Latch(false)
        do {
            let watcher = Released(released)
            let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor) { [watcher] in
                withExtendedLifetime(watcher) {}
                lost.record($0)
            }
            withExtendedLifetime(connection) {}
        }
        try released.wait(for: "the connection to let go of its threads") { $0 }
        #expect(lost.count == 0)
    }
}

/// Says it was released.
private final class Released: Sendable {
    private let latch: Latch<Bool>
    init(_ latch: Latch<Bool>) { self.latch = latch }
    deinit { latch.update { $0 = true } }
}

/// What `whenLost` was told, readable from the test's thread.
private final class Lost: Sendable {
    private let told = Latch<[DaemonError]>([])

    @Sendable func record(_ error: DaemonError) {
        told.update { $0.append(error) }
    }

    var count: Int { told.current.count }

    /// The first loss, once there is one.
    func first() throws -> DaemonError {
        try told.wait(for: "the connection to be lost") { $0.first }
    }
}
