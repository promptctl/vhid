import Foundation
import OwnThread
import TestClock
import Time
import Testing
@testable import Doctor
@testable import Helper
@testable import Installations

/// The status call as doctor makes it, against a far end of the test's own on a real XPC
/// connection: an anonymous listener in this process, so each reading is what a real
/// round trip ending that way comes back as, and nothing but who answers is faked.
/// [LAW:behavior-not-structure]
@Suite(.ownThread) struct DaemonProbeTests {
    /// How the far end meets the call. One type, the outcomes as values.
    /// [LAW:one-type-per-behavior]
    enum Answer: Sendable {
        /// Admitted, and answers with this holder.
        case holder(Int32?)
        /// Nobody holds them, and a release a client was owed failed.
        case leftHeld
        /// Refuses the connection, as the daemon refuses a signature it does not admit.
        case refuseTheConnection
        /// Admitted, and never answers.
        case never
        /// Admitted, and answers the call with an error of its own.
        case fail
        /// Admitted, and refuses the call as a daemon whose devices are not up.
        case devicesDown
    }

    private final class FarEnd: NSObject, HelperService, NSXPCListenerDelegate, @unchecked Sendable {
        private let answer: Answer
        private let lock = NSLock()
        /// Replies withheld rather than dropped, so a dropped reply cannot pass as silence.
        private var withheld: [(NSNumber?, Bool, Error?) -> Void] = []

        init(_ answer: Answer) { self.answer = answer }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            if case .refuseTheConnection = answer { return false }
            connection.exportedInterface = .helper()
            connection.exportedObject = self
            connection.resume()
            return true
        }

        func holding(reply: @escaping (NSNumber?, Bool, Error?) -> Void) {
            switch answer {
            case .holder(let pid): reply(pid.map { NSNumber(value: $0) }, false, nil)
            case .leftHeld: reply(nil, true, nil)
            case .fail: reply(nil, false, NSError(domain: "fake", code: 7, userInfo: [NSLocalizedDescriptionKey: "refused by the fake"]))
            case .devicesDown: reply(nil, false, NSError(domain: Installation.refusalDomain, code: Installation.devicesDownCode, userInfo: [NSLocalizedDescriptionKey: "devices not up: the driver is not activated"]))
            case .never, .refuseTheConnection: lock.lock(); withheld.append(reply); lock.unlock(); reached.open()
            }
        }

        /// Opened when a status reply is withheld: the call has reached the far end.
        let reached = Latch()

        func lastFailure(reply: @escaping (String?, Date?) -> Void) { Issue.record("doctor asked for the last failure"); reply(nil, nil) }
        func cursor(reply: @escaping (Double, Double, Error?) -> Void) { Issue.record("doctor read the cursor"); reply(0, 0, nil) }
        func layout(reply: @escaping ([NSNumber], Error?) -> Void) { Issue.record("doctor read the layout"); reply([], nil) }

        // A status call is all doctor sends; any device act reaching here is a failure.
        func down(usage: UInt16, by deadline: UInt64, reply: @escaping (Error?) -> Void) { Issue.record("doctor pressed a key"); reply(nil) }
        func releaseAll(by deadline: UInt64, reply: @escaping (Error?) -> Void) { Issue.record("doctor released keys"); reply(nil) }
        func hold(usages: [UInt16], by deadline: UInt64, reply: @escaping (Error?) -> Void) { Issue.record("doctor held keys"); reply(nil) }
        func buttonDown(_ button: UInt8, by deadline: UInt64, reply: @escaping (Error?) -> Void) { Issue.record("doctor pressed a button"); reply(nil) }
        func releaseButtons(by deadline: UInt64, reply: @escaping (Error?) -> Void) { Issue.record("doctor released buttons"); reply(nil) }
        func holdButtons(_ buttons: UInt32, by deadline: UInt64, reply: @escaping (Error?) -> Void) { Issue.record("doctor held buttons"); reply(nil) }
        func move(x: Int8, y: Int8, by deadline: UInt64, reply: @escaping (Error?) -> Void) { Issue.record("doctor moved the pointer"); reply(nil) }
        func scroll(vertical: Int8, horizontal: Int8, by deadline: UInt64, reply: @escaping (Error?) -> Void) { Issue.record("doctor scrolled"); reply(nil) }
        func leave(reply: @escaping (Error?) -> Void) { Issue.record("doctor left"); reply(nil) }
    }

    /// Reads a far end answering as told. The listener holds its delegate weakly, so both
    /// are held here until the reading is taken.
    ///
    /// On a test clock nothing moves, so a reading answered is never a silence however
    /// slowly the far end answers.
    private func reading(_ answer: Answer, invalidated: Bool = false, by deadline: Deadline = .within(.seconds(5), on: ManualClock().timeline)) -> DaemonReading {
        let far = FarEnd(answer)
        let listener = NSXPCListener.anonymous()
        listener.delegate = far
        listener.resume()
        if invalidated { listener.invalidate() }
        let helper = { HelperConnection(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), service: "ai.promptctl.vhid.tests.far", timeline: deadline.timeline, replyTimeout: .seconds(5)) }
        let read = DaemonProbe.reading(by: deadline, helper)
        withExtendedLifetime((far, listener)) {}
        return read
    }

    @Test func aDaemonNobodyHoldsAnswersWithNoHolder() {
        #expect(reading(.holder(nil)) == .answered(.nobody))
    }

    @Test func aDaemonAnotherClientHoldsNamesItsPid() {
        #expect(reading(.holder(41)) == .answered(.client(pid: 41)))
    }

    /// Devices a client left held are not free: the reading says so.
    @Test func aDaemonLeftHeldSaysSo() {
        #expect(reading(.leftHeld) == .answered(.leftHeld))
    }

    /// A refused connection is the signature, told apart from a service nobody holds.
    @Test func aRefusedConnectionIsThisSignatureRefused() {
        #expect(reading(.refuseTheConnection) == .refusedThisVhid)
    }

    @Test func aServiceNobodyHoldsIsUnreachable() {
        let read = reading(.holder(nil), invalidated: true)
        guard case .unreachable = read else { Issue.record("read \(read)"); return }
    }

    @Test func aDaemonThatNeverAnswersIsSilentAtTheDeadline() throws {
        let clock = ManualClock(), far = FarEnd(.never), listener = NSXPCListener.anonymous(), ended = Latch()
        listener.delegate = far
        listener.resume()
        let deadline = Deadline.within(.milliseconds(200), on: clock.timeline)
        nonisolated(unsafe) var read: DaemonReading?
        Thread.detachNewThread {
            read = DaemonProbe.reading(by: deadline) { HelperConnection(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), service: "ai.promptctl.vhid.tests.far", timeline: clock.timeline, replyTimeout: .seconds(5)) }
            ended.open()
        }
        far.reached.wait("the status call to reach the far end")
        clock.advance(by: .milliseconds(200))
        try #require(ended.wait("the reading to give up"))
        guard case .silent = read else { Issue.record("read \(String(describing: read))"); return }
        withExtendedLifetime((far, listener)) {}
    }

    /// A reading whose limit the rows before it spent asks the daemon nothing, and says so
    /// with the limit and how far in it was: not a silence, which would send a person to a
    /// daemon's log for an answer it was never asked for.
    @Test func aReadingWhoseLimitHasPassedAsksNothing() {
        let clock = ManualClock()
        let deadline = Deadline.within(.seconds(30), on: clock.timeline)
        clock.advance(by: .seconds(31))
        let read = DaemonProbe.reading(by: deadline) {
            Issue.record("a connection was made")
            return HelperConnection(connection: NSXPCConnection(machServiceName: "ai.promptctl.vhid.tests.nobody"), service: "ai.promptctl.vhid.tests.nobody", timeline: clock.timeline, replyTimeout: .seconds(5))
        }
        #expect(read == .unasked(Deadline.Passed(limit: .seconds(30), spent: .seconds(31))))
    }

    /// A daemon listening without its devices is read by its code, carrying why.
    @Test func aDaemonWhoseDevicesAreDownSaysWhy() {
        #expect(reading(.devicesDown) == .devicesDown(reason: "devices not up: the driver is not activated"))
    }

    /// An answer this build cannot classify is kept whole, in the words it came with.
    @Test func aFailureNoneOfThoseNameIsShownAsWhatItSaid() {
        let read = reading(.fail)
        guard case .failed(let reason) = read else { Issue.record("read \(read)"); return }
        #expect(reason == "refused by the fake")
    }

    /// A refusal followed by an answer is a daemon that went away mid-call and came back,
    /// not a refused signature: the second connection's reading stands.
    @Test func aRefusalThatDoesNotRepeatIsNotTheSignature() {
        let refusing = NSXPCListener.anonymous(), answering = NSXPCListener.anonymous()
        let (no, yes) = (FarEnd(.refuseTheConnection), FarEnd(.holder(nil)))
        refusing.delegate = no; answering.delegate = yes
        refusing.resume(); answering.resume()
        let endpoints = [refusing.endpoint, answering.endpoint]
        var asked = 0
        let timeline = ManualClock().timeline
        let read = DaemonProbe.reading(by: .within(.seconds(5), on: timeline)) {
            defer { asked += 1 }
            return HelperConnection(connection: NSXPCConnection(listenerEndpoint: endpoints[asked]), service: "ai.promptctl.vhid.tests.far", timeline: timeline, replyTimeout: .seconds(5))
        }
        #expect(read == .answered(.nobody))
        withExtendedLifetime((refusing, answering, no, yes)) {}
    }
}
