import Foundation
import Keystrokes
import Pointing
import OwnThread
import Testing
@testable import VirtualHID
import Waiting

/// What the connection does between requests, which is where a long-lived one spends
/// nearly all of its life. Measured on the daemon: it hangs up on a client that has sent
/// nothing for fifteen seconds, and answering its status pushes does not count as sending.
@Suite(.ownThread) struct ConnectionTests {
    /// A heartbeat goes out on its own, with nobody asking anything. Timed against a short
    /// interval so the test watches for the behaviour rather than sleeping the daemon's
    /// three seconds. [LAW:behavior-not-structure]
    @Test func aHeartbeatGoesOutWhileNothingIsBeingAsked() throws {
        let fake = FakeDaemon()
        let connection = try fake.connect(heartbeatEvery: .milliseconds(20))
        try fake.awaitFrame(.control(.heartbeat, payload: []))
        withExtendedLifetime(connection) {}
    }

    /// A status the daemon pushes while nothing is in flight is recorded and answered: the
    /// reading does not wait for a request to happen inside of.
    @Test func aStatusPushedBetweenRequestsIsRecordedAndAnswered() throws {
        let fake = FakeDaemon()
        let connection = try fake.connect()
        let pushed = try fake.push([(.keyboardReady, true)])
        #expect(throws: Never.self) { try connection.wait(for: .keyboardReady, within: .seconds(2)) }
        try fake.awaitFrame(.response(id: pushed, payload: []))
        withExtendedLifetime(connection) {}
    }

    /// The daemon going away is an event, told once to whoever holds the connection, and
    /// every request after it fails by the same name rather than by a broken pipe on the
    /// next write. [LAW:no-silent-failure]
    @Test func theDaemonHangingUpIsToldOnceAndFailsEveryLaterRequest() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let device = VirtualKeyboard(daemon: try fake.connect(whenLost: lost.record), reportTimeout: .seconds(2))
        fake.hangUp()
        #expect(try lost.first() == .closed)
        #expect(throws: DaemonError.closed) { try device.down(.leftShift) }
        #expect(throws: DaemonError.closed) { try device.releaseAll() }
        #expect(lost.count == 1)
    }

    /// A write that fails is the same loss as a stream that ends, found by the thread that
    /// writes rather than the one that reads: told once, thrown from the request whose frame
    /// found it, and every later request fails by the same name. [LAW:single-enforcer]
    ///
    /// The write is made to fail by shutting this side's sending half, which makes the
    /// next write fail with EPIPE while the reader goes on reading. Not the daemon's
    /// receiving half: measured, a peer's SHUT_RD leaves this side's writes succeeding on
    /// XNU, so that would test nothing.
    @Test func aWriteThatFailsIsTheLossToldOnceAndThrownFromTheRequestThatFoundIt() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try fake.connect(whenLost: lost.record)
        #expect(shutdown(fake.clientDescriptor, SHUT_WR) == 0)
        let failed = DaemonError.socket("write", EPIPE)
        #expect(throws: failed) { try connection.request(.keyboardInitialize, within: .seconds(2)) }
        #expect(try lost.first() == failed)
        #expect(throws: failed) { try connection.request(.keyboardReset, within: .seconds(2)) }
        #expect(lost.count == 1)
    }

    /// A daemon that stops talking without hanging up - suspended, or wedged - is as gone
    /// as one that closed the stream, and is found out by its silence rather than waited
    /// on forever. [LAW:no-ambient-temporal-coupling]
    @Test func aDaemonThatSaysNothingForThePatienceIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try fake.connect(patience: .milliseconds(100), whenLost: lost.record)
        #expect(try lost.first() == .silent)
        withExtendedLifetime(connection) {}
    }

    /// A daemon that stops mid-frame is the same silence, noticed in the middle of a read
    /// rather than between frames.
    @Test func aDaemonThatStopsMidFrameIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        // Half a header, on the wire before the connection reads anything: the reader's first
        // read is the one that stops partway, however late its thread runs.
        try fake.sendRaw([0, 0])
        let connection = try fake.connect(patience: .milliseconds(100), whenLost: lost.record)
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
        let connection = try fake.connect(whenLost: lost.record)
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
        let daemon = try fake.connect(whenLost: lost.record)
        let keyboard = VirtualKeyboard(daemon: daemon, reportTimeout: .seconds(2))
        let mouse = VirtualPointing(daemon: daemon, reportTimeout: .seconds(2))
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
        let keyboard = VirtualKeyboard(daemon: try fake.connect(whenLost: lost.record), reportTimeout: .seconds(2))
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
        let daemon = try fake.connect(whenLost: lost.record)
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
            try daemon.send(.response(id: id, payload: FakeDaemon.payload(frames.first ?? [])))
            for said in frames { try daemon.push(said) }
        }
        let lost = Lost()
        let daemon = try fake.connect(whenLost: lost.record)
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
            guard case .request(let id, let payload) = frame else { return }
            guard requestSent(payload).request != DaemonConnection.Request.keyboardInitialize.rawValue else { try daemon.lapse(); return }
            try daemon.send(.response(id: id, payload: []))
        }
        let connection = try fake.connect()
        #expect(throws: DaemonError.silent) { try connection.request(.keyboardInitialize, within: .seconds(2)) }
        let forgotten = try #require(fake.received.compactMap { if case .request(let id, _) = $0 { id } else { nil } }.first)
        try fake.send(.response(id: forgotten, payload: []))
        #expect(throws: Never.self) { try connection.request(.keyboardReset, within: .seconds(2)) }
    }

    /// A daemon that stops draining its socket without hanging up - and keeps talking, so
    /// its silence never shows on the reading side - stalls a write once the kernel's
    /// buffers are full. The write is bounded by the patience like a read, and past it the
    /// connection ends, named for the write side it stalled on, and every request on it
    /// with it, rather than holding the writer, and every writer behind it, for good.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// The frames are the largest this side sends, 4100 bytes, three of them against the
    /// 8 KB of send space the test sets on the pair: the fake reads one, the space holds one
    /// more, and the third finds it full part way through. The requests' clock is held
    /// still, so none of them ends but by the loss.
    @Test func aWriteThePeerStopsDrainingEndsAsAStalledWriteWithinThePatience() throws {
        // Reads one frame, then talks without listening: a heartbeat every 20 ms until the
        // client hangs up, and not one more read.
        let fake = FakeDaemon { _, daemon in
            let hungUp = Latch<Bool>()
            let talking = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ConnectionTests.talking"))
            talking.schedule(deadline: .now(), repeating: .milliseconds(20))
            talking.setEventHandler {
                guard (try? daemon.send(.control(.heartbeat, payload: []))) == nil else { return }
                talking.cancel()
                hungUp.open()
            }
            talking.resume()
            try hungUp.waitOpen("the client to hang up")
        }
        try fake.limitSendSpace(to: 8192)
        let lost = Lost()
        let connection = try fake.connect(patience: .seconds(1), whenLost: lost.record)
        let payload = [UInt8](repeating: 0, count: Frame.largestBody - 12)
        let thrown = Latch<[DaemonError]>([])
        for _ in 0..<3 {
            DispatchQueue(label: "ConnectionTests.request").async {
                do { try connection.request(.postKeyboardInputReport, payload, within: .seconds(2)) }
                catch let error as DaemonError { thrown.update { $0.append(error) } }
                catch { Issue.record("a request threw \(error), which is not the daemon's") }
            }
        }
        let ended = try thrown.wait(for: "the three requests to end") { $0.count == 3 }
        #expect(try lost.first() == .writeStalled)
        #expect(lost.count == 1)
        #expect(ended == [.writeStalled, .writeStalled, .writeStalled])
    }

    /// A request its limit kept from going out costs the connection nothing: no byte of it
    /// reached the daemon, which is not the one that was silent, and the next request is
    /// answered. [LAW:no-silent-failure]
    @Test func aRequestWhoseLimitIsSpentBeforeItIsSentIsUnsentAndTheConnectionGoesOn() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try fake.connect(whenLost: lost.record)
        #expect(throws: DaemonError.unsent) { try connection.request(.keyboardReset, within: .zero) }
        #expect(throws: Never.self) { try connection.request(.keyboardReset, within: .seconds(2)) }
        #expect(fake.requestPayloads.count == 1)
        #expect(lost.count == 0)
    }

    /// A request whose frame the peer stopped draining part way ends at its own limit,
    /// however long the daemon's patience, as a stalled write: the limit is the caller's,
    /// and the patience is the connection's. A request asked behind it goes into the outbox
    /// behind the stuck frame and, its limit ended there, is taken back unsent on the
    /// thread that asked, while the write is still stuck: one that waited for the write
    /// instead would never end. Neither is the connection's loss.
    /// [LAW:no-ambient-temporal-coupling]
    @Test func aRequestStalledPartWayEndsAtItsLimitAndOneBehindItIsUnsent() throws {
        let stalled = try StalledWrite(within: .milliseconds(200))
        #expect(throws: DaemonError.unsent) { try stalled.connection.request(.keyboardReset, within: .zero) }
        stalled.fake.clock.advance(by: .milliseconds(200))
        #expect(try stalled.ended() == .writeStalled)
        #expect(stalled.lost.count == 0)
    }

    /// A stalled write holds no one but the writers behind it: a wait for the daemon's word
    /// ends at its own limit while the write is still stuck. [LAW:no-ambient-temporal-coupling]
    ///
    /// The write's own limit is let pass only once the wait has ended, so the wait cannot
    /// have ended because the write did.
    @Test func aWaitEndsAtItsLimitWhileAWriteIsStalled() throws {
        let stalled = try StalledWrite(within: .milliseconds(200))
        let waited = Latch<DaemonError?>(nil)
        DispatchQueue(label: "ConnectionTests.wait").async {
            do { try stalled.connection.wait(for: .keyboardReady, within: .zero) }
            catch { waited.update { $0 = error as? DaemonError } }
        }
        #expect(try waited.wait(for: "the wait to end") { $0 != nil } == .notReady(awaiting: .keyboardReady, said: [:]))
        #expect(stalled.thrown.state == nil)
    }

    /// This side hanging up is not the daemon's doing, and is not reported as it.
    @Test func hangingUpOurselvesTellsNobody() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let letGo = Latch<Bool>()
        do {
            let held = Held(letGo)
            let connection = try fake.connect(whenLost: { [held] error in withExtendedLifetime(held) { lost.record(error) } })
            withExtendedLifetime(connection) {}
        }
        // The callback is let go with the link, which the reading thread holds until it has
        // read the end of the stream and ended: past that, it has had its every chance.
        try letGo.waitOpen("the reading thread to end")
        #expect(lost.count == 0)
    }
}

/// What `whenLost` was told, waited on from the test's thread.
private final class Lost: Sendable {
    private let told = Latch<[DaemonError]>([])

    @Sendable func record(_ error: DaemonError) {
        told.update { $0.append(error) }
    }

    var count: Int { told.state.count }

    /// The first error, once there is one.
    func first() throws(Hung) -> DaemonError {
        try told.wait(for: "the connection to be lost") { !$0.isEmpty }[0]
    }
}

/// A request whose frame is stuck part way out, and its connection. The fake reads one
/// small frame and then nothing, and the frame after it is larger than the send space, so
/// once its first bytes are on the wire it can neither finish nor be taken back.
private final class StalledWrite: Sendable {
    let fake: FakeDaemon
    let lost = Lost()
    let connection: DaemonConnection
    let thrown = Latch<DaemonError?>(nil)
    /// Lets the fake read again once the test is done with it, so its thread ends on the
    /// client's hang-up like every other fake's.
    private let done = Latch<Bool>()

    /// The stalled request is made `within` its limit, on the fake's clock.
    init(within limit: Duration) throws {
        let read = Latch<Bool>()
        let done = done
        fake = FakeDaemon { _, _ in
            read.open()
            try done.waitOpen("the test to finish with a stalled write")
        }
        try fake.limitSendSpace(to: 2048)
        // A patience past the test's life: the write ends only with the hang-up.
        let connection = try fake.connect(patience: .seconds(3600), whenLost: lost.record)
        self.connection = connection
        // Read whole and never answered; it ends with the connection.
        DispatchQueue(label: "ConnectionTests.unanswered").async {
            _ = try? connection.request(.keyboardReset, within: .seconds(3600))
        }
        try read.waitOpen("the fake to read the first frame")
        let payload = [UInt8](repeating: 0, count: Frame.largestBody - 12)
        let thrown = thrown
        DispatchQueue(label: "ConnectionTests.stalled").async {
            do { try connection.request(.postKeyboardInputReport, payload, within: limit) }
            catch { thrown.update { $0 = error as? DaemonError } }
        }
        try fake.awaitUnread()
    }

    deinit { done.open() }

    /// What the stalled request ended in, once it has.
    func ended() throws(Hung) -> DaemonError? {
        try thrown.wait(for: "the stalled request to end") { $0 != nil }
    }
}

/// Opens its latch when the last holder lets it go.
private final class Held: Sendable {
    private let letGo: Latch<Bool>

    init(_ letGo: Latch<Bool>) { self.letGo = letGo }

    deinit { letGo.open() }
}
