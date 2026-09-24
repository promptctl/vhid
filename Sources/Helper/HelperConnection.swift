import Installations
import Foundation

/// One connection to the helper, and the two devices reached over it.
///
/// [LAW:effects-at-boundaries] The XPC connection is the effect, and it is the whole of
/// what this type adds. Everything above it - which character, which keys, where the
/// pointer should end up, whether the target app is still in front - is decided in the
/// user's own process against types that know nothing about privilege.
///
/// One connection and not one per device, because the helper serves one client at a time
/// and a keyboard and a mouse in one process are one client: two connections would have
/// the second refused as busy by the first. [LAW:one-source-of-truth]
///
/// Synchronous on purpose. Each call waits for the helper's acknowledgement before the
/// next report goes out, because reports posted back to back are lost in the driver and a
/// lost key-up leaves a key held for macOS to repeat. The waiting is not a sleep: the
/// daemon answers every request, and the answer is what the pacing is built on.
///
/// Callable from any thread: the connection is, and each call keeps what it is waiting on
/// in an `Outcome` of its own, so two callers on two threads share nothing but the wire.
public final class HelperConnection: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let replyTimeout: Duration

    /// Whether anything has been sent over this connection. The connection is lazy, so
    /// until something is, the daemon has never seen it and holds nothing for it.
    private let spoken = NSLock()
    private var hasSpoken = false

    /// The connection's failure, or the helper's silence, as one thing a caller can catch.
    ///
    /// [LAW:types-are-the-program] The cause is a value and the words are made from it, so
    /// a reader that has to tell a refused signature from a service nobody holds reads
    /// the domain and code rather than parsing a sentence. NSXPC says "couldn't
    /// communicate" for both, and only the code tells them apart.
    public struct Unreachable: Error, CustomStringConvertible {
        public enum Cause: Sendable, Hashable {
            /// The connection failed, with the domain and code it failed with.
            case connection(domain: String, code: Int, description: String)
            /// Nothing came back before the deadline.
            case silence(Duration)
            /// The far end is something other than a helper.
            case notAHelper
        }

        public let cause: Cause

        public var description: String {
            switch cause {
            case .connection(let domain, let code, let description): "the helper could not be reached: \(description) (\(domain) \(code))"
            case .silence(let deadline): "the helper did not answer in \(deadline)"
            case .notAHelper: "the helper answered with something that is not a helper"
            }
        }
    }

    /// Connects to the helper's Mach service. The connection is lazy - launchd starts the
    /// job on the first call, not here - so a helper that is not installed is discovered
    /// when a key is first pressed rather than at construction.
    ///
    /// `replyTimeout` bounds each call: a helper that neither answers nor drops the
    /// connection is unreachable at the deadline rather than a caller blocked for good.
    /// `installation` says whose daemon this reaches. It has no default: installations run
    /// side by side, and a connection that guessed would type through another copy's
    /// keyboard. [LAW:no-silent-failure]
    public convenience init(installation: Installation, replyTimeout: Duration = .seconds(5)) {
        self.init(connection: NSXPCConnection(machServiceName: installation.service, options: .privileged), replyTimeout: replyTimeout)
    }

    /// Over a connection someone else made, which is how a test puts a service of its own
    /// on the far end. [LAW:decomposition]
    init(connection: NSXPCConnection, replyTimeout: Duration) {
        self.connection = connection
        self.replyTimeout = replyTimeout
        connection.remoteObjectInterface = NSXPCInterface(with: HelperService.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    /// Hands the devices back to the daemon, and returns once they are free.
    ///
    /// A connection that never spoke never reached the daemon, so there is nothing to hand
    /// back. Asking anyway would be the connection's first message: it would claim the
    /// devices only to free them, and fail as busy while someone else holds them.
    /// [LAW:dataflow-not-control-flow] Whether it spoke is a fact of the connection,
    /// recorded by `call`, not a guess about which verbs send reports.
    public func leave() throws {
        spoken.lock()
        let reached = hasSpoken
        spoken.unlock()
        guard reached else { return }
        try call { service, reply in service.leave(reply: reply) }
    }

    /// Which process holds the devices, or nil when none does.
    ///
    /// Not a word on the devices, so it leaves this connection as unspoken as it found it:
    /// a `leave` after it still has nothing to hand back. [LAW:dataflow-not-control-flow]
    public func status() throws -> Int32? {
        try exchange { service, reply in service.status { holder, error in reply(error.map { .failed($0) } ?? .answered(holder?.int32Value)) } }
    }

    /// The keyboard over this connection.
    public var keyboard: HelperKeyboard { HelperKeyboard(helper: self) }

    /// The mouse over this connection.
    public var mouse: HelperMouse { HelperMouse(helper: self) }

    /// The first word back about one call, from whichever of the two ways it can end
    /// speaks first. Its own object because both speak from the connection's queue after
    /// the call may have returned: a late one writes here, into something that outlives the
    /// call, and never into a local that does not. [LAW:no-ambient-temporal-coupling]
    private final class Outcome<Answer>: @unchecked Sendable {
        private let lock = NSLock()
        private let spoken = DispatchSemaphore(value: 0)
        private var word: Word<Answer>?

        func say(_ word: Word<Answer>) {
            lock.lock()
            if self.word == nil { self.word = word }
            lock.unlock()
            spoken.signal()
        }

        /// The word, or nil when none came in time.
        func await(_ timeout: Duration) -> Word<Answer>? {
            let nanoseconds = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
            guard spoken.wait(timeout: .now() + .nanoseconds(Int(nanoseconds))) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            return word
        }
    }

    /// What the helper said back about one call.
    enum Word<Answer> {
        case answered(Answer)
        case failed(Error)
    }

    /// One act on the devices: the connection has spoken from here on, and the reply is an
    /// acknowledgement or a refusal.
    func call(_ body: (HelperService, @escaping (Error?) -> Void) -> Void) throws {
        spoken.lock()
        hasSpoken = true
        spoken.unlock()
        try exchange { service, reply in body(service) { error in reply(error.map { .failed($0) } ?? .answered(())) } }
    }

    /// One round trip, with the reply turned back into a value or a throw.
    ///
    /// [LAW:no-silent-failure] An XPC call can fail in three ways that look nothing alike -
    /// the helper refused, the connection did, or nobody said anything - and a client that
    /// only reads the first types into a dead service forever. All three arrive here, and
    /// all three throw.
    private func exchange<Answer>(_ body: (HelperService, @escaping (Word<Answer>) -> Void) -> Void) throws -> Answer {
        let outcome = Outcome<Answer>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let failed = error as NSError
            outcome.say(.failed(Unreachable(cause: .connection(domain: failed.domain, code: failed.code, description: failed.localizedDescription))))
        }
        guard let service = proxy as? HelperService else { throw Unreachable(cause: .notAHelper) }
        body(service) { outcome.say($0) }
        switch outcome.await(replyTimeout) {
        case .answered(let answer): return answer
        case .failed(let error): throw error
        case nil:
            // A helper silent this long is taken as gone, and the connection with it: every
            // call after this one, the leave included, fails at once rather than waiting out
            // a deadline of its own. The daemon releases what it held when it sees this.
            connection.invalidate()
            throw Unreachable(cause: .silence(replyTimeout))
        }
    }
}
