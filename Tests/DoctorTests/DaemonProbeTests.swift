import Foundation
import Testing
@testable import Doctor
@testable import Helper

/// The status call as doctor makes it, against a far end of the test's own on a real XPC
/// connection: an anonymous listener in this process, so each reading is what a real
/// round trip ending that way comes back as, and nothing but who answers is faked.
/// [LAW:behavior-not-structure]
@Suite struct DaemonProbeTests {
    /// How the far end meets the call. One type, the outcomes as values.
    /// [LAW:one-type-per-behavior]
    enum Answer: Sendable {
        /// Admitted, and answers with this holder.
        case holder(Int32?)
        /// Refuses the connection, as the daemon refuses a signature it does not admit.
        case refuseTheConnection
        /// Admitted, and never answers.
        case never
        /// Admitted, and answers the call with an error of its own.
        case fail
    }

    private final class FarEnd: NSObject, HelperService, NSXPCListenerDelegate, @unchecked Sendable {
        private let answer: Answer
        private let lock = NSLock()
        /// Replies withheld rather than dropped, so a dropped reply cannot pass as silence.
        private var withheld: [(NSNumber?, Error?) -> Void] = []

        init(_ answer: Answer) { self.answer = answer }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            if case .refuseTheConnection = answer { return false }
            connection.exportedInterface = NSXPCInterface(with: HelperService.self)
            connection.exportedObject = self
            connection.resume()
            return true
        }

        func status(reply: @escaping (NSNumber?, Error?) -> Void) {
            switch answer {
            case .holder(let pid): reply(pid.map { NSNumber(value: $0) }, nil)
            case .fail: reply(nil, NSError(domain: "fake", code: 7, userInfo: [NSLocalizedDescriptionKey: "refused by the fake"]))
            case .never, .refuseTheConnection: lock.lock(); withheld.append(reply); lock.unlock()
            }
        }

        // A status call is all doctor sends; any device act reaching here is a failure.
        func down(usage: UInt16, reply: @escaping (Error?) -> Void) { Issue.record("doctor pressed a key"); reply(nil) }
        func releaseAll(reply: @escaping (Error?) -> Void) { Issue.record("doctor released keys"); reply(nil) }
        func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { Issue.record("doctor pressed a button"); reply(nil) }
        func releaseButtons(reply: @escaping (Error?) -> Void) { Issue.record("doctor released buttons"); reply(nil) }
        func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { Issue.record("doctor moved the pointer"); reply(nil) }
        func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) { Issue.record("doctor scrolled"); reply(nil) }
        func leave(reply: @escaping (Error?) -> Void) { Issue.record("doctor left"); reply(nil) }
    }

    /// Reads a far end answering as told. The listener holds its delegate weakly, so both
    /// are held here until the reading is taken.
    private func reading(_ answer: Answer, invalidated: Bool = false, replyTimeout: Duration = .seconds(20)) async -> DaemonReading {
        let far = FarEnd(answer)
        let listener = NSXPCListener.anonymous()
        listener.delegate = far
        listener.resume()
        if invalidated { listener.invalidate() }
        let helper = HelperConnection(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), replyTimeout: replyTimeout)
        // On a thread of its own: the call blocks until the far end answers, and a wait on
        // the cooperative pool can starve the reply. [LAW:no-ambient-temporal-coupling]
        let read = await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: DaemonProbe.reading(from: helper)) }.start()
        }
        withExtendedLifetime((far, listener)) {}
        return read
    }

    @Test func aDaemonNobodyHoldsAnswersWithNoHolder() async {
        #expect(await reading(.holder(nil)) == .answered(holder: nil))
    }

    @Test func aDaemonAnotherClientHoldsNamesItsPid() async {
        #expect(await reading(.holder(41)) == .answered(holder: 41))
    }

    /// A refused connection is the signature, told apart from a service nobody holds.
    @Test func aRefusedConnectionIsThisSignatureRefused() async {
        #expect(await reading(.refuseTheConnection) == .refusedThisSignature)
    }

    @Test func aServiceNobodyHoldsIsUnreachable() async {
        let read = await reading(.holder(nil), invalidated: true)
        guard case .unreachable = read else { Issue.record("read \(read)"); return }
    }

    @Test func aDaemonThatNeverAnswersIsSilentAtTheDeadline() async {
        let read = await reading(.never, replyTimeout: .milliseconds(200))
        guard case .silent = read else { Issue.record("read \(read)"); return }
    }

    /// An answer this build cannot classify is kept whole, in the words it came with.
    @Test func aFailureNoneOfThoseNameIsShownAsWhatItSaid() async {
        let read = await reading(.fail)
        guard case .failed(let reason) = read else { Issue.record("read \(read)"); return }
        #expect(reason.contains("refused by the fake"), "\(reason)")
    }
}
