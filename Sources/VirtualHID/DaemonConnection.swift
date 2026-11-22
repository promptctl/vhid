import Foundation
import Timeline

/// One connection to Karabiner-VirtualHIDDevice-Daemon over its Unix domain stream
/// socket. Every failure names what the daemon did or did not say. [LAW:no-silent-failure]
///
/// Why a daemon and not the driver: opening the driver extension's user client requires
/// `com.apple.developer.driverkit.userclient-access` naming
/// `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice`, which Apple grants per application
/// identifier and which only pqrs's own daemon holds. Root does not help; measured, in
/// low-talker's 3ti.2 spike. So the daemon is the way in.
///
/// **The caller must be root.** The socket's directory is mode 0700 owned by root, so a
/// process that is not root cannot see the socket at all. That is stated here once and
/// never re-checked inland: a privilege this type cannot acquire is not a condition for it
/// to keep testing. [LAW:no-defensive-null-guards]
///
/// **The socket is read by one thread for the life of the connection.** The daemon talks
/// when nobody has asked it anything - a heartbeat every three seconds, a health check
/// now and then, a status push when the driver changes state - and it hangs up on a
/// client that has said nothing for fifteen seconds, measured on this Mac. A connection
/// read only while a request was in flight went quiet between calls and was found dead
/// by the next write. So the reading is not part of asking; it is a lifecycle with its own
/// owner, and asking is writing a request and waiting to be told the answer arrived.
/// [LAW:no-ambient-temporal-coupling]
///
/// **The socket is written by one thread too.** Every frame this side sends - a request, a
/// heartbeat, an answer to something the daemon asked - joins one outbox, and the writer
/// takes them from it in order. No lock is held across a write and no caller writes, so a
/// daemon that stops draining its socket stalls the writer and nobody else: a caller waits
/// on its answer by its own deadline, and is told at that deadline how far its request
/// got. [LAW:single-enforcer]
///
/// **One connection carries both devices.** The daemon keeps a keyboard and a pointing
/// device per client connection and destroys both when the client hangs up, so a client
/// that owns a keyboard and a mouse holds one of these and hands it to each.
public final class DaemonConnection: Sendable {
    static let socketPath = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock"
    /// The version this side speaks, from `virtual_hid_device_service/client.hpp`. Two
    /// bytes, and native-endian unlike everything around it - the framing is big-endian
    /// and the report inside is little-endian, and none of the three announces itself.
    static let clientProtocolVersion: UInt16 = 7
    /// The daemon's own cadence, measured: it sends a heartbeat every three seconds and
    /// drops a client silent for fifteen. Matching it keeps this side well inside the
    /// patience of a daemon whose patience is not written down anywhere this side can read.
    static let heartbeatInterval: Duration = .seconds(3)
    /// How long the daemon may say nothing before it is taken for gone: its own fifteen
    /// seconds, mirrored. A peer that stalled without closing - suspended, wedged mid-frame
    /// - sends no heartbeat and no end of stream, and a reader that only waits for one of
    /// those would wait forever, sending its own heartbeats into the dark.
    static let patience: Duration = .seconds(15)

    /// The request table, by index, from `virtual_hid_device_service/request.hpp`.
    enum Request: UInt8 {
        case keyboardInitialize = 0
        case keyboardTerminate = 1
        case keyboardReset = 2
        case pointingInitialize = 3
        case pointingTerminate = 4
        case pointingReset = 5
        case postKeyboardInputReport = 6
        case postPointingInputReport = 11
    }

    /// The status table, by index, from `virtual_hid_device_service/response.hpp`.
    public enum Status: UInt8, Sendable {
        case none = 0
        case driverActivated = 1
        case driverConnected = 2
        case driverVersionMismatched = 3
        case keyboardReady = 4
        case pointingReady = 5

        /// The words `DaemonError` reports this status in.
        public var name: String {
            switch self {
            case .none: "none"
            case .driverActivated: "driver activated"
            case .driverConnected: "driver connected"
            case .driverVersionMismatched: "driver version mismatched"
            case .keyboardReady: "keyboard ready"
            case .pointingReady: "pointing ready"
            }
        }
    }

    private let link: Link

    /// Connects to the daemon at the path above.
    ///
    /// `whenLost` is told, once, from the reading thread, when the connection ends for
    /// any reason but this side hanging up: the daemon closed it, the socket failed, the
    /// wire carried something this side cannot read, or the daemon took back a status it
    /// had said held. Every later request throws the
    /// same failure, so a caller that only ever asks can leave it be; a process that
    /// holds the connection open across long silences is the one that needs to hear.
    public convenience init(whenLost: @escaping @Sendable (DaemonError) -> Void = { _ in }) throws {
        guard FileManager.default.fileExists(atPath: Self.socketPath) else { throw DaemonError.noSocket(path: Self.socketPath) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DaemonError.socket("socket", errno) }
        // Connected before anything reads it: a reader on an unconnected socket reports a
        // failure that is really this side's own ordering. The descriptor has no owner
        // yet, so a refused connection closes it here and nowhere else.
        do { try Self.connect(descriptor) } catch { close(descriptor); throw error }
        try self.init(fileDescriptor: descriptor, whenLost: whenLost)
    }

    /// A connection over a descriptor someone else opened. This is the seam that makes
    /// the wire protocol testable: a `socketpair` puts a fake daemon on the other end, so
    /// the framing, the deadlines, the heartbeats and the request/response matching are
    /// exercised over a real socket rather than mocked away. [LAW:decomposition] The
    /// protocol and the pipe it runs over are two things, and only one of them needs root.
    ///
    /// The heartbeat interval and the patience are parameters so a test can watch a
    /// heartbeat go out, or a silence be noticed, without waiting the daemon's seconds.
    init(fileDescriptor: Int32, heartbeatEvery interval: Duration = DaemonConnection.heartbeatInterval, patience: Duration = DaemonConnection.patience, whenLost: @escaping @Sendable (DaemonError) -> Void = { _ in }) throws {
        // The link owns the descriptor from this line, so an initializer that throws past
        // it still closes exactly once, when the link goes.
        link = Link(socket: fileDescriptor, heartbeatEvery: interval, patience: patience, whenLost: whenLost)
        try refuseSIGPIPE(fileDescriptor)
        try neverBlock(fileDescriptor)
        link.startReading()
        link.startWriting()
    }

    /// Hangs up. The reading thread sees the end of the stream and the writer the hang-up;
    /// each finishes and lets go of the link, and the descriptor closes with the last.
    /// [LAW:single-enforcer]
    deinit {
        link.hangUp()
    }

    private static func connect(_ socket: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        precondition(path.count <= MemoryLayout.size(ofValue: address.sun_path), "the socket path outgrew sun_path")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw DaemonError.socket("connect", errno) }
    }

    // MARK: - Requests

    /// The daemon's latest word on each status it has ever sent.
    var status: [Status: Bool] { link.currentStatus }

    /// Sends a request and waits for the daemon's answer to it, by `deadline`. Every
    /// request is answered, including a posted report, so waiting on the answer is real
    /// flow control rather than a sleep guessed at. [LAW:no-ambient-temporal-coupling]
    ///
    /// Answers how far into its deadline the answer came. A request that was not answered
    /// says why and whether any of it may have reached the daemon, which is what a device's
    /// record of what it holds is kept by.
    @discardableResult
    func request(_ request: Request, _ payload: [UInt8] = [], by deadline: Deadline) throws(Unanswered) -> Duration {
        let version = Self.clientProtocolVersion
        return try link.ask([UInt8(version & 0xff), UInt8(version >> 8), request.rawValue] + payload, by: deadline)
    }

    /// Waits until the daemon has said `status` holds, however long ago it said so. The
    /// wait is on the daemon's word, never a sleep - but note what the word costs: the
    /// daemon asks the driver once a second, so readiness is *discovered* on the next tick
    /// rather than when it happened, and this takes up to a second however fast the device
    /// really was. That is why a connection is meant to be held open rather than made per
    /// call.
    ///
    /// A deadline missed here is `.notReady` carrying the daemon's latest word on each
    /// status, never `.silent`: bring-up reaches this only after the daemon answered its
    /// request, so what it said, or that it said nothing about the driver, is the reason.
    func wait(for status: Status, by deadline: Deadline) throws {
        try link.wait(by: deadline, until: { $0.status[status] == true }, missed: { .notReady(awaiting: status, said: $0.status) })
    }

    /// Brings one device up: sends its initialize request with `payload`, then waits for
    /// the daemon's word that the device is `ready`, both by `deadline`. Both devices start
    /// this way and differ only in the three values, so the bringing up is one function of
    /// them. [LAW:one-type-per-behavior]
    ///
    /// Each cost is counted from when the deadline was made, on its clock.
    func initialize(_ request: Request, _ payload: [UInt8], until ready: Status, by deadline: Deadline) throws -> Startup {
        // When the answer arrived, read by the thread that read it. Timing the first frame
        // of the readiness wait instead - as this once did, and low-talker's spike before
        // it - reports the first status push under a name that says the daemon had not
        // spoken yet, when answering the request is exactly what it just did.
        let answered: Duration
        do { answered = try self.request(request, payload, by: deadline) } catch { throw error.reason }
        try wait(for: ready, by: deadline)
        return Startup(answered: answered, ready: deadline.spent)
    }

    /// A request the daemon did not answer: why, and whether any of it may have reached the
    /// daemon. One that never left this side changed nothing there; one that may have can
    /// have changed anything it asked for. [LAW:types-are-the-program]
    struct Unanswered: Error, Equatable {
        let reason: DaemonError
        let mayHaveReached: Bool
    }

    /// The daemon's status payload, decoded: pairs of (status, value). Pure, and separate
    /// from recording for the reason the framing is - a transposed pair records the wrong
    /// status as true and nothing about that looks wrong at runtime. [LAW:decomposition]
    static func statusPairs(_ pairs: [UInt8]) throws(DaemonError) -> [(Status, Bool)] {
        guard pairs.count % 2 == 0 else { throw DaemonError.malformed("a status payload of \(pairs.count) bytes, which is not pairs") }
        return try stride(from: 0, to: pairs.count, by: 2).map { (index) throws(DaemonError) in
            guard let status = Status(rawValue: pairs[index]) else { throw DaemonError.malformed("status \(pairs[index]), which this was not written for") }
            return (status, pairs[index + 1] != 0)
        }
    }
}

/// What the reading thread and the connection share: the socket, and everything the
/// daemon has said that someone might be waiting on.
///
/// Its own type rather than state on `DaemonConnection` so that the thread holds this and
/// not the connection: a thread holding the connection would keep it alive for as long as
/// the daemon kept talking, and `deinit` would never come. The connection hangs up; the
/// thread notices, ends, and lets go; the descriptor closes with the last holder.
/// [LAW:no-shared-mutable-globals] One lock guards all of it, and every read and write of
/// the fields below happens under it.
private final class Link: @unchecked Sendable {
    private let socket: Int32
    private let heartbeatInterval: Duration
    private let patience: Duration
    /// On the clock that stops with the Mac: the silence that says anything about the
    /// daemon is silence while both were awake, and a clock that ran on through the lid
    /// being closed would find the daemon fifteen seconds gone the instant it opened. The
    /// one clock the link reads, and the one every caller's deadline is made on.
    /// [LAW:no-ambient-temporal-coupling]
    private let timeline = Timeline.suspending
    private let whenLost: @Sendable (DaemonError) -> Void
    private let guarded = NSCondition()
    private var nextRequestID: UInt64 = 1
    /// Every request someone is still waiting on, and how far it has got. [LAW:one-source-of-truth]
    /// One table rather than a set of the asked and a set of the answered: an id is here
    /// while a waiter wants it and nowhere once it does not.
    private var requests: [UInt64: Asked] = [:]
    /// The frames for the writer, in the order they are to go.
    private var outbox: [Outgoing] = []
    var status: [DaemonConnection.Status: Bool] = [:]
    /// When the daemon last sent a byte, on `timeline`. Read and written by the reading
    /// thread alone, so it needs no lock: nothing else has a reason to know.
    private lazy var lastHeard = timeline.now()
    /// Set once, by whichever side ended the connection, and never cleared: every wait
    /// after it throws this, because the daemon cannot answer on a stream that is gone.
    private var failure: DaemonError?
    /// True when this side hung up, so the end of the stream that follows is not reported
    /// as the daemon's doing.
    private var hungUp = false

    init(socket: Int32, heartbeatEvery interval: Duration, patience: Duration, whenLost: @escaping @Sendable (DaemonError) -> Void) {
        self.socket = socket
        heartbeatInterval = interval
        self.patience = patience
        self.whenLost = whenLost
    }

    deinit {
        close(socket)
    }

    var currentStatus: [DaemonConnection.Status: Bool] {
        guarded.lock(); defer { guarded.unlock() }
        return status
    }

    // MARK: Asking

    /// Puts a request in the outbox and waits for its answer, the connection's end, or
    /// `deadline`, in that order of precedence: an answer that arrived is an answer, even on
    /// a stream that ended just after it.
    ///
    /// A miss is read off how far the request got, so it says what the daemon can have
    /// seen. [LAW:no-silent-failure] A request still in the outbox is taken back out and
    /// is not sent; one being written is a write the daemon stopped taking; one written is
    /// a daemon that did not answer. Nothing is queued on a connection that has ended, nor
    /// past a deadline already passed.
    func ask(_ body: [UInt8], by deadline: Deadline) throws(DaemonConnection.Unanswered) -> Duration {
        guarded.lock(); defer { guarded.unlock() }
        if let failure { throw DaemonConnection.Unanswered(reason: failure, mayHaveReached: false) }
        guard !deadline.passed else { throw DaemonConnection.Unanswered(reason: .unsent, mayHaveReached: false) }
        let id = nextRequestID
        nextRequestID += 1
        // The waiter's own record, which the reader and the writer reach through the table.
        let asked = Asked(deadline: deadline)
        requests[id] = asked
        outbox.append(.request(id, Frame.request(id: id, payload: body).bytes))
        guarded.broadcast()
        // On every way out, so an answer to a request nobody waits on any more is dropped
        // at the door rather than kept for a collector that never comes.
        defer { requests[id] = nil }
        while true {
            if let answered = asked.answered { return answered }
            if let failure { throw DaemonConnection.Unanswered(reason: failure, mayHaveReached: asked.progress.mayHaveReached) }
            if deadline.passed {
                if case .queued = asked.progress { outbox.removeAll { $0.carries(id) } }
                throw DaemonConnection.Unanswered(reason: asked.progress.missed, mayHaveReached: asked.progress.mayHaveReached)
            }
            deadline.wait(on: guarded)
        }
    }

    /// Blocks until `satisfied` holds, the connection has failed, or the deadline passes,
    /// in that order of precedence, as `ask` does. [LAW:no-silent-failure] A daemon that
    /// says nothing is a named failure at the deadline, not a wait without end - named by
    /// `missed`, from what the link had heard by then.
    func wait(by deadline: Deadline, until satisfied: (Link) -> Bool, missed: (Link) -> DaemonError) throws {
        guarded.lock(); defer { guarded.unlock() }
        while true {
            if satisfied(self) { return }
            if let failure { throw failure }
            guard !deadline.passed else { throw missed(self) }
            deadline.wait(on: guarded)
        }
    }

    // MARK: Writing

    /// Writes the outbox until the connection ends, on a thread that holds this link and
    /// nothing else, for the reason the reader does.
    func startWriting() {
        let thread = Thread { [self] in
            do throws(DaemonError) {
                while let next = take() {
                    try write(next.bytes)
                    wrote(next)
                }
            } catch {
                lost(error)
            }
        }
        thread.name = "DaemonConnection.writer"
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// The next frame to write, once there is one, or nil once the connection has ended.
    private func take() -> Outgoing? {
        guarded.lock(); defer { guarded.unlock() }
        while outbox.isEmpty, failure == nil, !hungUp { guarded.wait() }
        guard failure == nil, !hungUp else { return nil }
        let next = outbox.removeFirst()
        // A request whose waiter has given up is no longer in the table, and is written
        // all the same: it left the outbox before the waiter could take it back.
        if case .request(let id, _) = next { requests[id]?.progress = .writing }
        return next
    }

    private func wrote(_ frame: Outgoing) {
        guarded.lock(); defer { guarded.unlock() }
        if case .request(let id, _) = frame { requests[id]?.progress = .written }
    }

    /// A frame for the writer that no waiter waits on. Only ever called with the lock held.
    private func enqueue(_ frame: Frame) {
        outbox.append(.unasked(frame.bytes))
        guarded.broadcast()
    }

    // MARK: Reading

    /// Reads until the stream ends, on a thread that holds this link and nothing else.
    func startReading() {
        let thread = Thread { [self] in
            do throws(DaemonError) {
                try readUntilTheEnd()
            } catch {
                lost(error)
            }
        }
        thread.name = "DaemonConnection.reader"
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// The next thing to do is always the same: wait for the daemon, the heartbeat's turn
    /// or the end of the patience, whichever comes first, then do whichever came.
    /// [LAW:dataflow-not-control-flow]
    private func readUntilTheEnd() throws(DaemonError) {
        var heartbeatDue = timeline.now() + heartbeatInterval
        while true {
            let readable = try ready(POLLIN, by: min(heartbeatDue, lastHeard + patience))
            if timeline.now() >= heartbeatDue {
                guarded.lock(); defer { guarded.unlock() }
                enqueue(.control(.heartbeat, payload: []))
                heartbeatDue += heartbeatInterval
            }
            if readable {
                try handle(try readFrame())
            }
            guard timeline.now() < lastHeard + patience else { throw DaemonError.silent }
        }
    }

    /// What every frame means to this side: a pushed status is recorded and answered with
    /// an empty response, as pqrs's own client does; a health check is answered; a
    /// response's status pairs are recorded and its request is marked answered, when, by
    /// its own deadline's clock, for whoever asked.
    private func handle(_ frame: Frame) throws(DaemonError) {
        guarded.lock(); defer { guarded.unlock() }
        switch frame {
        case .control(.healthCheck, _):
            enqueue(.control(.healthCheckResponse, payload: []))
        case .control:
            break
        case .request(let id, let payload):
            try record(payload)
            enqueue(.response(id: id, payload: []))
        case .response(let id, let payload):
            try record(payload)
            // Only a request still waited on: an answer to a forgotten one records nothing.
            // [LAW:dataflow-not-control-flow]
            requests[id]?.answer()
        }
        guarded.broadcast()
    }

    /// Records what the daemon said about its status. Version skew throws from here, before
    /// the frame that carried it can count as an answer: a waiter woken by the loss then
    /// finds the failure and not an acknowledgement. [LAW:single-enforcer] A driver built
    /// for another protocol accepts reports and then does something other than what they
    /// say, so there is no degraded mode to continue into.
    ///
    /// A status taken back throws from here the same way, and ends the connection with it.
    /// The daemon goes on answering a posted report after the driver has gone, measured on
    /// studious 2026-10-01, so its answers cannot say the devices are still there; its
    /// status is the only word on that, and it is read on every frame, not only while a
    /// device is being brought up. The driver coming back does not undo it: the daemon
    /// makes the devices afresh on the same connection, and whatever was held on the old
    /// ones is not held on the new, which is what a new connection says and an old one
    /// cannot. [LAW:no-silent-failure]
    private func record(_ pairs: [UInt8]) throws(DaemonError) {
        let before = status
        for (status, value) in try DaemonConnection.statusPairs(pairs) {
            self.status[status] = value
        }
        guard status[.driverVersionMismatched] != true else { throw DaemonError.driverVersionMismatched }
        let takenBack = before.filter { $0.value && status[$0.key] == false }.keys.min { $0.rawValue < $1.rawValue }
        if let takenBack { throw DaemonError.withdrawn(takenBack, said: status) }
    }

    // MARK: Ending

    /// This side is done. The stream ends for the reader, which is how it stops.
    func hangUp() {
        guarded.lock()
        hungUp = true
        guarded.broadcast()
        guarded.unlock()
        shutdown(socket, SHUT_RDWR)
    }

    /// The connection ended and this side did not end it. Recorded once, every waiter
    /// woken to throw it, and the owner told - after the lock is released, so an owner
    /// that answers by touching the connection cannot deadlock against this thread.
    private func lost(_ error: DaemonError) {
        guarded.lock()
        let theirs = record(loss: error)
        guarded.unlock()
        if theirs { whenLost(error) }
    }

    /// The locked half of losing the connection: the first loss is the failure every
    /// waiter throws, and every waiter is woken. Answers whether the owner is owed the
    /// news, which is once, and never for an end this side asked for. Only ever called
    /// with the lock held.
    ///
    /// The stream ends here for the daemon too. A loss this side declares - a status taken
    /// back, a version it was not built for, a silence - is on a socket the daemon still
    /// counts as a client, and it keeps that client's devices, and whatever is down on
    /// them, until the client goes: a mouse button held through a keyboard taken back
    /// stayed held. [LAW:single-enforcer] So a connection that has ended has ended on the
    /// wire, whoever still holds the object.
    private func record(loss error: DaemonError) -> Bool {
        let first = failure == nil
        if first { failure = error }
        outbox.removeAll()
        shutdown(socket, SHUT_RDWR)
        guarded.broadcast()
        return first && !hungUp
    }

    // MARK: The socket

    private func readFrame() throws(DaemonError) -> Frame {
        let length = try Frame.bodyLength(header: read(4))
        return try Frame.decode(body: read(length))
    }

    /// Only ever called from the writer, the one thread that writes, so no frame lands
    /// inside another, and without the lock, so no waiter waits on the socket.
    ///
    /// Each chunk is waited for within the patience, like a read: a peer that stops
    /// draining without hanging up fills the kernel's buffer, and past the patience that
    /// is the same silence a stalled read is.
    private func write(_ bytes: [UInt8]) throws(DaemonError) {
        try transfer(bytes.count, waitingFor: POLLOUT, until: { timeline.now() + patience }, named: "write", moved: {}) { offset in
            bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
        }
    }

    /// Reads exactly `count` bytes, each chunk waited for within the patience since the
    /// daemon was last heard: a peer that stops mid-frame is as gone as one that stops
    /// between frames.
    private func read(_ count: Int) throws(DaemonError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try transfer(count, waitingFor: POLLIN, until: { lastHeard + patience }, named: "read", moved: { lastHeard = timeline.now() }) { offset in
            bytes[offset...].withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
        }
        return bytes
    }

    /// Moves `count` bytes through the socket a chunk at a time, `step` moving what it can
    /// from an offset, each chunk waited for by `due` and followed by `moved`.
    /// [LAW:single-enforcer] The one loop over the socket, so a short transfer, a readiness
    /// gone again before the call and the end of the stream each have one reading.
    private func transfer(_ count: Int, waitingFor events: Int32, until due: () -> Duration, named call: String,
                          moved: () -> Void, _ step: (_ offset: Int) -> Int) throws(DaemonError) {
        var offset = 0
        while offset < count {
            guard try ready(events, by: due()) else { throw DaemonError.silent }
            let done = uninterrupted { step(offset) }
            // Readiness reported and gone again before the call: back to waiting for it.
            if done < 0, errno == EAGAIN { continue }
            guard done > 0 else { throw done == 0 ? DaemonError.closed : DaemonError.socket(call, errno) }
            offset += done
            moved()
        }
    }

    /// Whether the socket is ready for `events` - something to read, or room to write - by
    /// `deadline`. The one wait on the socket, so the end of the stream, an interrupted
    /// call and a failed poll each have one reading. [LAW:single-enforcer]
    private func ready(_ events: Int32, by due: Duration) throws(DaemonError) -> Bool {
        while true {
            var descriptor = pollfd(fd: socket, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, max(.zero, due - timeline.now()).wholeMilliseconds)
            // Around the loop rather than retried in place, so the time actually left is
            // consulted again.
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw DaemonError.socket("poll", errno) }
            return ready > 0
        }
    }
}

/// A request someone is waiting on: how far it has got, and when it was answered, by the
/// clock of the deadline it was asked by.
///
/// The answer apart from the progress, because the two are told by different threads: the
/// reader can read an answer before the writer has said the last of the request was
/// written, and a progress that ran on to "written" after that would read as unanswered.
///
/// A class the waiter holds and the table names, so the waiter reads its own record and
/// never looks itself up. Every field is read and written under the link's lock.
private final class Asked {
    let deadline: Deadline
    var progress: Progress = .queued
    var answered: Duration?

    init(deadline: Deadline) { self.deadline = deadline }

    func answer() { answered = deadline.spent }

    /// How far a request's bytes have gone.
    enum Progress {
        case queued, writing, written

        /// Whether any of it can have reached the daemon.
        var mayHaveReached: Bool { if case .queued = self { false } else { true } }

        /// What a deadline missed at this point says.
        var missed: DaemonError {
            switch self {
            case .queued: .unsent
            case .writing: .stalled
            case .written: .silent
            }
        }
    }
}

/// A frame for the writer: a request someone waits on, by its id, or a frame nobody does.
private enum Outgoing {
    case request(UInt64, [UInt8])
    case unasked([UInt8])

    var bytes: [UInt8] {
        switch self {
        case .request(_, let bytes), .unasked(let bytes): bytes
        }
    }

    func carries(_ id: UInt64) -> Bool {
        if case .request(id, _) = self { true } else { false }
    }
}
