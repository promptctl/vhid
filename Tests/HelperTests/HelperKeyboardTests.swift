import Foundation
import Keystrokes
import OwnThread
import Pointing
import Testing
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
        private var pointing: [String] = []
        /// Replies never given, held so that a reply that was dropped rather than
        /// withheld cannot pass as the same thing.
        private var withheld: [(Error?) -> Void] = []

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
            }
        }

        private func note(_ what: String, _ reply: @escaping (Error?) -> Void) {
            lock.lock(); pointing.append(what); lock.unlock()
            respond(reply)
        }

        func down(usage: UInt16, reply: @escaping (Error?) -> Void) {
            lock.lock(); usages.append(usage); lock.unlock()
            respond(reply)
        }

        func releaseAll(reply: @escaping (Error?) -> Void) {
            respond(reply)
        }

        func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { note("button \(button)", reply) }
        func releaseButtons(reply: @escaping (Error?) -> Void) { note("release", reply) }
        func holdButtons(_ buttons: UInt32, reply: @escaping (Error?) -> Void) { note("hold buttons \(buttons)", reply) }
        func hold(usages: [UInt16], reply: @escaping (Error?) -> Void) { note("hold \(usages.sorted())", reply) }
        func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { note("move \(x) \(y)", reply) }
        func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) { note("scroll \(vertical) \(horizontal)", reply) }
        func leave(reply: @escaping (Error?) -> Void) { note("leave", reply) }
        func status(reply: @escaping (NSNumber?, Error?) -> Void) {
            lock.lock(); pointing.append("status"); lock.unlock()
            respond { reply($0 == nil ? NSNumber(value: 41) : nil, $0) }
        }
        func lastFailure(reply: @escaping (String?, Date?) -> Void) { reply(failure.0, failure.1) }
        func cursor(reply: @escaping (Double, Double, Error?) -> Void) {
            lock.lock(); pointing.append("cursor"); lock.unlock()
            respond { reply(812.5, 400, $0) }
        }
        func displays(reply: @escaping ([NSNumber], Error?) -> Void) {
            lock.lock(); pointing.append("displays"); lock.unlock()
            respond { reply([0, 0, 1920, 1080, 1920, -200, 1280, 800].map { NSNumber(value: $0) }, $0) }
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

    /// The bound ends a test whose far end is broken; it measures nothing, so it sits far
    /// above any round trip. [LAW:no-ambient-temporal-coupling]
    private func helper(_ answer: Answer, failure: (String?, Date?) = (nil, nil), replyTimeout: Duration = .seconds(20)) -> (HelperConnection, FarEnd) {
        let service = Service(answer, failure: failure)
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        return (HelperConnection(connection: connection, service: "ai.promptctl.vhid.tests.far", replyTimeout: replyTimeout), FarEnd(listener: listener, service: service))
    }

    @Test func anAcknowledgedKeyGoesDownAndTheCallReturns() throws {
        let (helper, far) = helper(.acknowledge)
        let keyboard = helper.keyboard
        try keyboard.down(.leftShift)
        try keyboard.releaseAll()
        #expect(far.service.asked == [Usage.leftShift.rawValue])
    }

    /// The mouse's four acts cross the same connection as the keyboard's, each as the
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

    /// `status` answers who holds the devices and is no act on them: the connection has
    /// still not spoken, so a `leave` after it sends nothing.
    @Test func statusAnswersTheHolderAndLeavesTheConnectionUnspoken() throws {
        let (helper, far) = helper(.acknowledge)
        #expect(try helper.status() == 41)
        try helper.leave()
        #expect(far.service.pointed == ["status"])
    }

    @Test func theCursorIsReadAndLeavesTheConnectionUnspoken() throws {
        let (helper, far) = helper(.acknowledge)
        #expect(try helper.cursor() == (812.5, 400))
        try helper.leave()
        #expect(far.service.pointed == ["cursor"])
    }

    /// The displays cross the wire as four numbers each and arrive as rectangles, a display
    /// above the main one's top included, and the read leaves the connection unspoken.
    @Test func theDisplaysAreReadAsRectangles() throws {
        let (helper, far) = helper(.acknowledge)
        #expect(try helper.displays() == [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: -200, width: 1280, height: 800)])
        try helper.leave()
        #expect(far.service.pointed == ["displays"])
    }

    /// A service that neither answers nor hangs up is unreachable at the deadline, rather
    /// than a caller blocked for good. [LAW:no-ambient-temporal-coupling]
    @Test func aServiceThatNeverAnswersIsUnreachableAtTheDeadline() throws {
        let (helper, far) = helper(.never, replyTimeout: .milliseconds(200))
        let began = ContinuousClock.now
        let unreachable = #expect(throws: HelperConnection.Unreachable.self) { try helper.keyboard.down(.space) }
        #expect(unreachable?.cause == .silence(.milliseconds(200)))
        #expect(ContinuousClock.now - began >= .milliseconds(200))
        // Held to the deadline: a far end gone early is unreachable for the wrong reason,
        // and a test that cannot tell the two apart proves nothing.
        withExtendedLifetime(far) {}
    }

    /// The wire's pair is one failure, or none, or a daemon this client does not
    /// understand - never half a failure shown as a whole one. [LAW:parse-dont-validate]
    @Test func theLastFailureIsBothHalvesOrNeither() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let (both, bothFar) = helper(.acknowledge, failure: ("the keyboard would not release", at))
        #expect(try both.lastFailure() == DaemonFailure(text: "the keyboard would not release", at: at))

        let (neither, neitherFar) = helper(.acknowledge)
        #expect(try neither.lastFailure() == nil)

        let (half, halfFar) = helper(.acknowledge, failure: ("a text with no time", nil))
        let garbled = #expect(throws: HelperConnection.Unreachable.self) { try half.lastFailure() }
        #expect(garbled?.cause == .notAHelper)
        withExtendedLifetime((bothFar, neitherFar, halfFar)) {}
    }
}
