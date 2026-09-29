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

    /// What this connection has been through, under one lock: whether anything has been
    /// sent over it, whether the daemon has ever run an act of it, and whether it was given up
    /// on after the daemon went silent. The connection is lazy, so until something is sent
    /// the daemon has never seen it and holds nothing for it.
    private let history = NSLock()
    private var hasSpoken = false
    private var hasActed = false
    private var abandoned: Duration?

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
            /// This connection was given up on after the daemon was silent this long, so
            /// nothing more crosses it.
            case abandoned(Duration)
        }

        public let service: String
        public let cause: Cause

        /// Whether the connection failed before reaching the daemon: nobody holds the
        /// service, or the daemon refused the connection as it opened. Either also ends a
        /// connection the daemon already served, which is why this alone proves nothing.
        var neverGotThrough: Bool {
            switch cause {
            case .connection(NSCocoaErrorDomain, NSXPCConnectionInvalid, _), .connection(NSCocoaErrorDomain, NSXPCConnectionInterrupted, _): true
            case .connection, .silence, .notAHelper, .abandoned: false
            }
        }

        /// Which link failed, in the words of what to do about it. The two codes NSXPC
        /// gives a client that never got through are named for what they mean here; any
        /// other is shown as it came.
        public var description: String {
            switch cause {
            case .connection(NSCocoaErrorDomain, NSXPCConnectionInvalid, _):
                "no launchd job answers \(service) (\(NSCocoaErrorDomain) \(NSXPCConnectionInvalid)): vhidd is not installed or not loaded"
            case .connection(NSCocoaErrorDomain, NSXPCConnectionInterrupted, _):
                "\(service) ended the connection (\(NSCocoaErrorDomain) \(NSXPCConnectionInterrupted)): vhidd refused this binary's signature, or exited while the call was in flight"
            case .connection(let domain, let code, let description): "\(service) could not be reached: \(description) (\(domain) \(code))"
            case .silence(let deadline): "\(service) did not answer in \(deadline)"
            case .notAHelper: "\(service) answered with something that is not vhidd's service"
            case .abandoned(let deadline): "the connection to \(service) was dropped after it did not answer in \(deadline)"
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
    /// A connection that never spoke never reached the daemon, so there is nothing to hand
    /// back, and asking would only add a failure to the one that stopped the caller.
    /// [LAW:dataflow-not-control-flow] Whether it spoke is a fact of the connection,
    /// recorded by `call`, not a guess about which verbs send reports.
    public func leave() throws {
        history.lock()
        let reached = hasSpoken
        history.unlock()
        guard reached else { return }
        try release { service, reply in service.leave(reply: reply) }
    }

    /// A call that frees what the daemon holds for this connection, which succeeds when
    /// its failure proves nothing is held.
    ///
    /// A release is always sent. What its failure means is the question: "a key may be
    /// held" is only true when the daemon could have set one down for this connection.
    /// Two failures prove it did not, and are the release having nothing to do:
    /// - the daemon turned the call away at the seat (`Installation.turnedAway`), which
    ///   it does only for a connection whose acts never reach the devices;
    /// - the connection never got through (4099, 4097) and the daemon never ran an act of
    ///   it.
    /// [LAW:single-enforcer] Read here, once, for the keyboard, the mouse and leaving.
    func release(_ body: (HelperService, @escaping (Error?) -> Void) -> Void) throws {
        do {
            try call(body)
        } catch let refused as Refused where Installation.turnedAway(domain: refused.domain, code: refused.code) {
            return
        } catch let unreachable as Unreachable where !acted && unreachable.neverGotThrough {
            return
        }
    }

    private var acted: Bool {
        history.lock(); defer { history.unlock() }
        return hasActed
    }

    /// Which process holds the devices, or nil when none does.
    ///
    /// Not a word on the devices, so it leaves this connection as unspoken as it found it:
    /// a `leave` after it still has nothing to hand back. [LAW:dataflow-not-control-flow]
    public func status() throws -> Int32? {
        try exchange { service, reply in service.status { holder, error in reply(error.map { .failed($0) } ?? .answered(holder?.int32Value)) } }
    }

    /// The daemon's most recent failure, or nil when it has had none since it started.
    ///
    /// [LAW:parse-dont-validate] The wire's pair becomes one optional here, once: a text
    /// without a time or a time without a text is a daemon this client does not
    /// understand, and is thrown as that rather than shown as half a failure.
    public func lastFailure() throws -> DaemonFailure? {
        let (text, at): (String?, Date?) = try exchange { service, reply in service.lastFailure { reply(.answered(($0, $1))) } }
        switch (text, at) {
        case (let text?, let at?): return DaemonFailure(text: text, at: at)
        case (nil, nil): return nil
        default: throw Unreachable(service: service, cause: .notAHelper)
        }
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

    /// One act on the devices: the connection has spoken from here on, and the reply is an
    /// acknowledgement or a refusal.
    func call(_ body: (HelperService, @escaping (Error?) -> Void) -> Void) throws {
        history.lock()
        hasSpoken = true
        history.unlock()
        let outcome = Result { try exchange { service, reply in body(service) { error in reply(error.map { .failed($0) } ?? .answered(())) } } }
        // The daemon ran this act: it acknowledged it, or reached the devices and failed
        // there. Not a refusal at the seat, the connection's failure, or silence.
        let ran = switch outcome {
        case .success: true
        case .failure(let refused as Refused): !Installation.turnedAway(domain: refused.domain, code: refused.code)
        case .failure: false
        }
        history.lock(); hasActed = hasActed || ran; history.unlock()
        try outcome.get()
    }

    /// One round trip, with the reply turned back into a value or a throw.
    ///
    /// [LAW:no-silent-failure] An XPC call can fail in three ways that look nothing alike -
    /// vhidd refused, the connection did, or nobody said anything - and a client that
    /// only reads the first types into a dead service forever. All three arrive here, and
    /// all three throw.
    private func exchange<Answer>(_ body: (HelperService, @escaping (Word<Answer>) -> Void) -> Void) throws -> Answer {
        history.lock()
        let gaveUp = abandoned
        history.unlock()
        if let gaveUp { throw Unreachable(service: service, cause: .abandoned(gaveUp)) }
        let outcome = Outcome<Answer>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let failed = error as NSError
            outcome.say(.failed(Unreachable(service: self.service, cause: .connection(domain: failed.domain, code: failed.code, description: failed.localizedDescription))))
        }
        guard let helper = proxy as? HelperService else { throw Unreachable(service: service, cause: .notAHelper) }
        body(helper) { outcome.say($0) }
        let word = outcome.await(replyTimeout)
        switch word {
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
            history.lock(); abandoned = replyTimeout; history.unlock()
            connection.invalidate()
            throw Unreachable(service: service, cause: .silence(replyTimeout))
        }
    }
}
