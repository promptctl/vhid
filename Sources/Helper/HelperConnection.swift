import Installations
import Foundation

/// One connection to vhidd, and the two devices reached over it.
///
/// [LAW:effects-at-boundaries] The XPC connection is the effect, and it is the whole of
/// what this type adds. Everything above it - which character, which keys, where the
/// pointer should end up, whether the target app is still in front - is decided in the
/// user's own process against types that know nothing about privilege.
///
/// One connection and not one per device, because vhidd serves one client at a time
/// and a keyboard and a mouse in one process are one client: two connections would have
/// the second refused as busy by the first. [LAW:one-source-of-truth]
///
/// Synchronous on purpose. Each call waits for vhidd's acknowledgement before the
/// next report goes out, because reports posted back to back are lost in the driver and a
/// lost key-up leaves a key held for macOS to repeat. The waiting is not a sleep: the
/// daemon answers every request, and the answer is what the pacing is built on.
///
/// Callable from any thread: the connection is, and each call keeps what it is waiting on
/// in an `Outcome` of its own, so two callers on two threads share nothing but the wire.
public final class HelperConnection: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let replyTimeout: Duration
    /// The Mach service dialled, which every failure names: installations run side by
    /// side, and "the helper" does not say which one did not answer.
    private let service: String

    /// Whether the daemon may hold anything for this connection: an act it acknowledged,
    /// or one that went unanswered and may have landed. An act refused, or one the
    /// connection never delivered, left nothing behind - so until one of the first two
    /// happens there is nothing to release and nothing to leave, and no key can be held.
    private let admission = NSLock()
    private var admitted = false

    /// The connection's failure, or vhidd's silence, as one thing a caller can catch.
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
            /// The far end is something other than vhidd's service.
            case notAHelper
        }

        public let service: String
        public let cause: Cause

        /// Which link failed, in the words of what to do about it. The two codes NSXPC
        /// gives a client that never got through are named for what they mean here; any
        /// other is shown as it came.
        public var description: String {
            switch cause {
            case .connection(NSCocoaErrorDomain, NSXPCConnectionInvalid, _):
                "no launchd job answers \(service) (\(NSCocoaErrorDomain) \(NSXPCConnectionInvalid)): the daemon is not installed or not loaded"
            case .connection(NSCocoaErrorDomain, NSXPCConnectionInterrupted, _):
                "\(service) ended the connection (\(NSCocoaErrorDomain) \(NSXPCConnectionInterrupted)): the daemon refused this binary's signature, or exited while the call was in flight"
            case .connection(let domain, let code, let description): "\(service) could not be reached: \(description) (\(domain) \(code))"
            case .silence(let deadline): "\(service) did not answer in \(deadline)"
            case .notAHelper: "\(service) answered with something that is not vhidd's service"
            }
        }
    }

    /// The daemon's own refusal of a call, with the words it gave and the service that gave
    /// them. The domain and code are kept so a reader tells the devices being down from any
    /// other refusal by its code. [LAW:types-are-the-program]
    public struct Refused: Error, CustomStringConvertible {
        public let service: String
        public let domain: String
        public let code: Int
        public let reason: String

        public var description: String { "\(service) refused: \(reason)" }
    }

    /// Connects to vhidd's Mach service. The connection is lazy - launchd starts the
    /// job on the first call, not here - so a vhidd that is not installed is discovered
    /// when a key is first pressed rather than at construction.
    ///
    /// `replyTimeout` bounds each call: a vhidd that neither answers nor drops the
    /// connection is unreachable at the deadline rather than a caller blocked for good.
    /// `installation` says whose daemon this reaches. It has no default: installations run
    /// side by side, and a connection that guessed would type through another copy's
    /// keyboard. [LAW:no-silent-failure]
    public convenience init(installation: Installation, replyTimeout: Duration = .seconds(5)) {
        self.init(connection: NSXPCConnection(machServiceName: installation.service, options: .privileged), service: installation.service, replyTimeout: replyTimeout)
    }

    /// Over a connection someone else made, which is how a test puts a service of its own
    /// on the far end. [LAW:decomposition]
    init(connection: NSXPCConnection, service: String, replyTimeout: Duration) {
        self.connection = connection
        self.service = service
        self.replyTimeout = replyTimeout
        connection.remoteObjectInterface = NSXPCInterface(with: HelperService.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    /// Hands the devices back to the daemon, and returns once they are free.
    ///
    public func leave() throws {
        try release { service, reply in service.leave(reply: reply) }
    }

    /// A call that frees what the daemon holds for this connection, sent only when it may
    /// hold something.
    ///
    /// A connection the daemon never admitted has nothing to hand back. Asking anyway would
    /// be the connection's first act: it would claim the devices only to free them, fail as
    /// busy while someone else holds them - and when the call before it failed because the
    /// daemon was unreachable or refusing, fail the same way and report a key "not
    /// released" that never went down. [LAW:dataflow-not-control-flow] Whether it was
    /// admitted is a fact of the connection, recorded by `call`, not a guess about which
    /// verbs send reports.
    func release(_ body: (HelperService, @escaping (Error?) -> Void) -> Void) throws {
        admission.lock()
        let holding = admitted
        admission.unlock()
        guard holding else { return }
        try call(body)
    }

    /// Which process holds the devices, or nil when none does.
    ///
    /// Not a word on the devices, so it leaves this connection as unadmitted as it found
    /// it: a `leave` after it still has nothing to hand back. [LAW:dataflow-not-control-flow]
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

    /// What vhidd said back about one call.
    enum Word<Answer> {
        case answered(Answer)
        case failed(Error)
    }

    /// One act on the devices, answered by an acknowledgement or a refusal. An act
    /// acknowledged, or one that went unanswered and so may have landed, admits the
    /// connection; one refused or never delivered leaves it as it was.
    func call(_ body: (HelperService, @escaping (Error?) -> Void) -> Void) throws {
        let outcome = Result { try exchange { service, reply in body(service) { error in reply(error.map { .failed($0) } ?? .answered(())) } } }
        let landed = switch outcome {
        case .success: true
        case .failure(let unreachable as Unreachable): unreachable.cause == .silence(replyTimeout)
        case .failure: false
        }
        admission.lock()
        admitted = admitted || landed
        admission.unlock()
        try outcome.get()
    }

    /// One round trip, with the reply turned back into a value or a throw.
    ///
    /// [LAW:no-silent-failure] An XPC call can fail in three ways that look nothing alike -
    /// vhidd refused, the connection did, or nobody said anything - and a client that
    /// only reads the first types into a dead service forever. All three arrive here, and
    /// all three throw.
    private func exchange<Answer>(_ body: (HelperService, @escaping (Word<Answer>) -> Void) -> Void) throws -> Answer {
        let outcome = Outcome<Answer>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let failed = error as NSError
            outcome.say(.failed(Unreachable(service: self.service, cause: .connection(domain: failed.domain, code: failed.code, description: failed.localizedDescription))))
        }
        guard let helper = proxy as? HelperService else { throw Unreachable(service: service, cause: .notAHelper) }
        body(helper) { outcome.say($0) }
        switch outcome.await(replyTimeout) {
        case .answered(let answer): return answer
        case .failed(let error as Unreachable): throw error
        case .failed(let error):
            // What the daemon replied: a plain NSError carrying its words, since that is all
            // NSXPC carries. Named for the service that said it. [LAW:no-silent-failure]
            let refused = error as NSError
            throw Refused(service: service, domain: refused.domain, code: refused.code, reason: refused.localizedDescription)
        case nil:
            // A vhidd silent this long is taken as gone, and the connection with it: every
            // call after this one, the leave included, fails at once rather than waiting out
            // a deadline of its own. The daemon releases what it held when it sees this.
            connection.invalidate()
            throw Unreachable(service: service, cause: .silence(replyTimeout))
        }
    }
}
