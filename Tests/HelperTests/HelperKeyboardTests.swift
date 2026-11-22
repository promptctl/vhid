import Foundation
import Installations
import Keystrokes
import OwnThread
import Pointing
import ScreenSpace
import ScreenSpaceTesting
import TestClock
import Testing
import Time
@testable import Helper

/// The client's side of the privilege seam, driven against a service of the test's own
/// on the far end of a real XPC connection: an anonymous listener in this process, so
/// what is exercised is the round trip and every way it ends, with nothing mocked but
/// who answers. [LAW:behavior-not-structure]
@Suite(.ownThread) struct HelperKeyboardTests {
    /// What the service on the far end does with a call. One type, three behaviours as
    /// values. [LAW:one-type-per-behavior]
    enum Answer: Sendable {
        case acknowledge
        case refuse(domain: String, code: Int)
        case never
    }

    /// The far end: a service that answers as told, and remembers what it was asked.
    private final class Service: NSObject, HelperService, NSXPCListenerDelegate, @unchecked Sendable {
        private let answer: Answer
        private let lock = NSLock()
        private var usages: [UInt16] = []
        private var deadlines: [UInt64] = []
        private var pointing: [String] = []
        /// Replies never given, held so that a reply that was dropped rather than
        /// withheld cannot pass as the same thing.
        private var withheld: [(Error?) -> Void] = []
        /// Opened when a reply is first withheld: the call has reached the far end.
        let reached = Latch()

        /// What `lastFailure` answers, as the wire's pair, so a test can hand back a half.
        private let failure: (String?, Date?)

        init(_ answer: Answer, failure: (String?, Date?) = (nil, nil)) {
            self.answer = answer
            self.failure = failure
        }

        var asked: [UInt16] {
            lock.lock(); defer { lock.unlock() }
            return usages
        }

        /// The deadline each key-down carried, as the wire's nanoseconds of uptime.
        var carried: [UInt64] {
            lock.lock(); defer { lock.unlock() }
            return deadlines
        }

        /// Every mouse call, in the wire's own integers.
        var pointed: [String] {
            lock.lock(); defer { lock.unlock() }
            return pointing
        }

        private func respond(_ reply: @escaping (Error?) -> Void) {
            switch answer {
            case .acknowledge:
                reply(nil)
            case .refuse(let domain, let code):
                reply(NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "refused by the fake"]))
            case .never:
                lock.lock(); withheld.append(reply); lock.unlock()
                reached.open()
            }
        }

        private func note(_ what: String, _ reply: @escaping (Error?) -> Void) {
            lock.lock(); pointing.append(what); lock.unlock()
            respond(reply)
        }

        func down(usage: UInt16, by deadline: UInt64, reply: @escaping (Error?) -> Void) {
            lock.lock(); usages.append(usage); deadlines.append(deadline); lock.unlock()
            respond(reply)
        }

        func releaseAll(by deadline: UInt64, reply: @escaping (Error?) -> Void) {
            respond(reply)
        }

        func buttonDown(_ button: UInt8, by deadline: UInt64, reply: @escaping (Error?) -> Void) { note("button \(button)", reply) }
        func releaseButtons(by deadline: UInt64, reply: @escaping (Error?) -> Void) { note("release", reply) }
        func holdButtons(_ buttons: UInt32, by deadline: UInt64, reply: @escaping (Error?) -> Void) { note("hold buttons \(buttons)", reply) }
        func hold(usages: [UInt16], by deadline: UInt64, reply: @escaping (Error?) -> Void) { note("hold \(usages.sorted())", reply) }
        func move(x: Int8, y: Int8, by deadline: UInt64, reply: @escaping (Error?) -> Void) { note("move \(x) \(y)", reply) }
        func scroll(vertical: Int8, horizontal: Int8, by deadline: UInt64, reply: @escaping (Error?) -> Void) { note("scroll \(vertical) \(horizontal)", reply) }
        func leave(reply: @escaping (Error?) -> Void) { note("leave", reply) }
        func holding(reply: @escaping (NSNumber?, Bool, Error?) -> Void) {
            lock.lock(); pointing.append("holding"); lock.unlock()
            respond { reply($0 == nil ? NSNumber(value: 41) : nil, false, $0) }
        }
        func lastFailure(reply: @escaping (String?, Date?) -> Void) { reply(failure.0, failure.1) }
        func cursor(reply: @escaping (Double, Double, Error?) -> Void) {
            lock.lock(); pointing.append("cursor"); lock.unlock()
            respond { reply(812.5, 400, $0) }
        }
        func layout(reply: @escaping ([NSNumber], Error?) -> Void) {
            lock.lock(); pointing.append("layout"); lock.unlock()
            respond { reply(HelperKeyboardTests.layout.record.map { NSNumber(value: $0) }, $0) }
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = .helper()
            connection.exportedObject = self
            connection.resume()
            return true
        }
    }

    /// The far end as one thing a test holds: the listener holds its delegate weakly, so
    /// a service held by nothing is gone before the first call, and the call fails as a
    /// connection failure whatever the test meant to try. [LAW:types-are-the-program]
    private struct FarEnd {
        let listener: NSXPCListener
        let service: Service
    }

    /// On a test clock, which only the test moves: a reply is waited for until it comes, and
    /// a silence is a silence when the test moves the clock past the limit.
    private func helper(_ answer: Answer, failure: (String?, Date?) = (nil, nil), replyTimeout: Duration = .seconds(5), clock: ManualClock = ManualClock()) -> (HelperConnection, FarEnd) {
        let service = Service(answer, failure: failure)
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        return (HelperConnection(connection: connection, service: "ai.promptctl.vhid.tests.far", timeline: clock.timeline, replyTimeout: replyTimeout), FarEnd(listener: listener, service: service))
    }

    @Test func anAcknowledgedKeyGoesDownAndTheCallReturns() throws {
        let (helper, far) = helper(.acknowledge)
        let keyboard = helper.keyboard
        try keyboard.down(.leftShift)
        try keyboard.releaseAll()
        #expect(far.service.asked == [Usage.leftShift.rawValue])
    }

    /// The mouse's four commands cross the same connection as the keyboard's, each as the
    /// wire's own integers: a button by number, a count by its signed byte.
    @Test func theMouseRidesTheSameConnectionAsTheKeyboard() throws {
        let (helper, far) = helper(.acknowledge)
        let mouse = helper.mouse
        try mouse.down(.left)
        try mouse.move(by: Move(x: Count(clamping: -3), y: Count(clamping: 127)))
        try mouse.scroll(by: Scroll(vertical: Count(clamping: 2), horizontal: Count(clamping: -1)))
        try mouse.releaseAll()
        #expect(far.service.pointed == ["button 1", "move -3 127", "scroll 2 -1", "release"])
    }

    /// A held set crosses as its usages, and a held button set as the report's bit field.
    @Test func heldSetsCrossAsTheWiresIntegers() throws {
        let (helper, far) = helper(.acknowledge)
        let (keyboard, mouse) = (helper.keyboard, helper.mouse)
        try keyboard.hold(HeldKeys([.leftShift, .space]))
        try keyboard.hold(.none)
        try mouse.hold([.left, .middle])
        try mouse.hold([])
        #expect(far.service.pointed == ["hold [44, 225]", "hold []", "hold buttons 5", "hold buttons 0"])
    }

    /// vhidd's refusal reaches the caller as the error vhidd sent, not as a
    /// connection failure. [LAW:no-silent-failure]
    @Test func theHelpersRefusalIsThrown() throws {
        let (helper, far) = helper(.refuse(domain: "fake", code: 7))
        let refusal = #expect(throws: HelperConnection.Refused.self) { try helper.keyboard.down(.space) }
        // The error itself when it is not the fake's, so a connection failure in its place
        // is read by its reason and not just by its domain.
        let heard = Comment(rawValue: refusal.map { "\($0 as Error)" } ?? "nothing was thrown")
        #expect(refusal?.domain == "fake", heard)
        #expect(refusal?.code == 7, heard)
        withExtendedLifetime(far) {}
    }

    /// A service that went away under an open connection is unreachable, said on the first
    /// call, with the connection's own domain and code. Which code is XPC's timing to
    /// choose: invalid, or interrupted if the connection had reached the listener first.
    /// Doctor asks twice for that reason (`DaemonProbe.reading`).
    @Test func aServiceThatWentAwayIsUnreachable() throws {
        let (helper, far) = helper(.acknowledge)
        far.listener.invalidate()
        let unreachable = #expect(throws: HelperConnection.Unreachable.self) { try helper.keyboard.down(.space) }
        guard case .connection(let domain, let code, _) = unreachable?.cause else {
            Issue.record("unreachable for another cause: \(String(describing: unreachable))")
            return
        }
        #expect(domain == NSCocoaErrorDomain)
        #expect([NSXPCConnectionInvalid, NSXPCConnectionInterrupted].contains(code))
    }

    /// `holding` answers who holds the devices and is no command to them: the connection has
    /// still not spoken, so a `leave` after it sends nothing. It was `status`, a pid alone,
    /// and that name is gone, so a mismatched pair fails at the lookup.
    @Test func holdingAnswersTheHolderAndLeavesTheConnectionUnspoken() throws {
        let (helper, far) = helper(.acknowledge)
        #expect(try helper.holding(by: .within(.seconds(5), on: ManualClock().timeline)) == .client(pid: 41))
        try helper.leave()
        #expect(far.service.pointed == ["holding"])
        #expect(protocol_getMethodDescription(HelperService.self, NSSelectorFromString("statusWithReply:"), true, true).name == nil)
    }

    /// A command carries its deadline across the wire, as the uptime instant the client stops
    /// waiting at: when it was asked, and the reply's limit after.
    @Test func aCommandCarriesTheInstantItsClientStopsWaiting() throws {
        let clock = ManualClock()
        clock.advance(by: .seconds(7))
        let (helper, far) = helper(.acknowledge, replyTimeout: .milliseconds(1500), clock: clock)
        try helper.keyboard.down(.space)
        #expect(far.service.carried == [Instant(sinceBoot: .milliseconds(8500)).nanoseconds])
    }

    /// vhidd saying it cannot tell whether a command reached the devices is no refusal: the
    /// caller is told the outcome is unknown, in vhidd's words.
    @Test func aCommandWhoseOutcomeVhiddCannotTellIsUnknownNotRefused() throws {
        let (helper, far) = helper(.refuse(domain: Installation.refusalDomain, code: Installation.outcomeUnknownCode))
        #expect(throws: HelperConnection.OutcomeUnknown(service: "ai.promptctl.vhid.tests.far", cause: .daemon("refused by the fake"))) { try helper.keyboard.down(.space) }
        withExtendedLifetime(far) {}
    }

    @Test func theCursorIsReadAndLeavesTheConnectionUnspoken() throws {
        let (helper, far) = helper(.acknowledge)
        #expect(try helper.cursor(by: .within(.seconds(5), on: ManualClock().timeline)) == (812.5, 400))
        try helper.leave()
        #expect(far.service.pointed == ["cursor"])
    }

    /// A main display and one above its top, asleep.
    static let layout = DisplayLayout.at([.at(0, 0, 1920, 1080), .at(1920, -200, 1280, 800)], asleep: [1])

    /// The layout crosses the wire as its record and arrives as the layout it was, the
    /// sleeping display above the main one's top included, and the read leaves the
    /// connection unspoken.
    @Test func theLayoutCrossesTheWireAsItself() throws {
        let (helper, far) = helper(.acknowledge)
        #expect(try helper.layout(by: .within(.seconds(5), on: ManualClock().timeline)) == Self.layout)
        try helper.leave()
        #expect(far.service.pointed == ["layout"])
    }

    /// The four-number record went out under the name `displays(reply:)`. The protocol no
    /// longer has it, so a client of an older build asking a daemon of this one fails at the
    /// lookup instead of reading six numbers a display as four.
    @Test func theOldRecordsNameIsGoneFromTheProtocol() {
        #expect(protocol_getMethodDescription(HelperService.self, NSSelectorFromString("displaysWithReply:"), true, true).name == nil)
        #expect(protocol_getMethodDescription(HelperService.self, #selector(HelperService.layout(reply:)), true, true).name != nil)
    }

    /// A command a service neither answers nor hangs up on ends at its deadline, rather than
    /// a caller blocked for good, and its outcome is unknown: the service may have done it.
    /// [LAW:no-ambient-temporal-coupling]
    @Test func aCommandAServiceNeverAnswersEndsAtTheDeadlineWithItsOutcomeUnknown() throws {
        let clock = ManualClock(), ended = Latch()
        let (helper, far) = helper(.never, replyTimeout: .milliseconds(200), clock: clock)
        nonisolated(unsafe) var said: (any Error)?
        Thread.detachNewThread {
            do { try helper.keyboard.down(.space) } catch { said = error }
            ended.open()
        }
        far.service.reached.wait("the call to reach the far end")
        clock.advance(by: .milliseconds(200))
        try #require(ended.wait("the call to give up"))
        #expect((said as? HelperConnection.OutcomeUnknown)?.cause == .silence(.milliseconds(200)))
        // Held to the deadline: a far end gone early is unreachable for the wrong reason,
        // and a test that cannot tell the two apart proves nothing.
        withExtendedLifetime(far) {}
    }

    /// The wire's pair is one failure, or none, or a daemon this client does not
    /// understand - never half a failure shown as a whole one. [LAW:parse-dont-validate]
    @Test func theLastFailureIsBothHalvesOrNeither() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let (both, bothFar) = helper(.acknowledge, failure: ("the keyboard would not release", at))
        #expect(try both.lastFailure(by: .within(.seconds(5), on: ManualClock().timeline)) == DaemonFailure(text: "the keyboard would not release", at: at))

        let (neither, neitherFar) = helper(.acknowledge)
        #expect(try neither.lastFailure(by: .within(.seconds(5), on: ManualClock().timeline)) == nil)

        let (half, halfFar) = helper(.acknowledge, failure: ("a text with no time", nil))
        let garbled = #expect(throws: HelperConnection.Unreachable.self) { try half.lastFailure(by: .within(.seconds(5), on: ManualClock().timeline)) }
        #expect(garbled?.cause == .notAHelper)
        withExtendedLifetime((bothFar, neitherFar, halfFar)) {}
    }
}
