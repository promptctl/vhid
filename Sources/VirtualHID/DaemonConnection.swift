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
/// owner, and so is the writing, and asking is handing the writer a request and waiting
/// to be told the answer arrived.
/// [LAW:no-ambient-temporal-coupling]
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

    /// Connects to the daemon at the path above, keeping request limits on `now`: the clock
    /// its owner keeps every other wait of the same work on.
    ///
    /// `whenLost` is told, once, from the connection's reading or writing thread, when the
    /// connection ends for any reason but this side hanging up: the daemon closed it, the
    /// socket failed, the daemon stopped taking what was written, the wire carried
    /// something this side cannot read, or the daemon took back a status it had said held. Every later request throws the
    /// same failure, so a caller that only ever asks can leave it be; a process that
    /// holds the connection open across long silences is the one that needs to hear.
    public convenience init(now: @escaping @Sendable () -> Duration, whenLost: @escaping @Sendable (DaemonError) -> Void) throws {
        guard FileManager.default.fileExists(atPath: Self.socketPath) else { throw DaemonError.noSocket(path: Self.socketPath) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DaemonError.socket("socket", errno) }
        // Connected before anything reads it: a reader on an unconnected socket reports a
        // failure that is really this side's own ordering. The descriptor has no owner
        // yet, so a refused connection closes it here and nowhere else.
        do { try Self.connect(descriptor) } catch { close(descriptor); throw error }
        try self.init(fileDescriptor: descriptor, now: now, whenLost: whenLost)
    }

    /// A connection over a descriptor someone else opened. This is the seam that makes
    /// the wire protocol testable: a `socketpair` puts a fake daemon on the other end, so
    /// the framing, the deadlines, the heartbeats and the request/response matching are
    /// exercised over a real socket rather than mocked away. [LAW:decomposition] The
    /// protocol and the pipe it runs over are two things, and only one of them needs root.
    ///
    /// The heartbeat interval and the patience are parameters so a test can watch a
    /// heartbeat go out, or a silence be noticed, without waiting the daemon's seconds.
    /// `now` is what a request's limit and a startup's timings are kept on, so a test holds
    /// it still and no answered request can miss, or moves it past a limit to miss one.
    init(
        fileDescriptor: Int32,
        heartbeatEvery interval: Duration = DaemonConnection.heartbeatInterval,
        patience: Duration = DaemonConnection.patience,
        now: @escaping @Sendable () -> Duration,
        whenLost: @escaping @Sendable (DaemonError) -> Void
    ) throws {
        // The link owns the descriptor from this line, so an initializer that throws past
        // it still closes exactly once, when the link goes.
        link = Link(socket: fileDescriptor, heartbeatEvery: interval, patience: patience, now: now, whenLost: whenLost)
        try refuseSIGPIPE(fileDescriptor)
        try neverBlock(fileDescriptor)
        link.start()
    }

    /// Hangs up. The reading thread sees the end of the stream, finishes, and lets go of
    /// the link, which is when the descriptor closes. [LAW:single-enforcer]
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

    /// The clock request deadlines are on: a caller makes its deadline from it at its own
    /// call, so every wait it has before the request, a lock's included, is spent from it.
    var now: @Sendable () -> Duration { link.now }

    /// Sends a request and waits for the daemon's answer to it, both by `deadline`, which
    /// the caller made at its call. Every request is answered, including a posted report,
    /// so waiting on the answer is real flow control rather than a sleep guessed at.
    /// [LAW:no-ambient-temporal-coupling]
    func request(_ request: Request, _ payload: [UInt8] = [], by deadline: Duration) throws {
        let version = Self.clientProtocolVersion
        try link.ask([UInt8(version & 0xff), UInt8(version >> 8), request.rawValue] + payload, by: deadline)
    }

    /// Waits until the daemon has said `status` holds, however long ago it said so, by
    /// `deadline`. The wait is on the daemon's word, never a sleep - but note what the word
    /// costs: the daemon asks the driver once a second, so readiness is *discovered* on the
    /// next tick rather than when it happened, and this takes up to a second however fast
    /// the device really was. That is why a connection is meant to be held open rather than
    /// made per call.
    ///
    /// A limit missed here is `.notReady` carrying the daemon's latest word on each status,
    /// never `.silent`: bring-up reaches this only after the daemon answered its request, so
    /// what it said, or that it said nothing about the driver, is the reason.
    func wait(for status: Status, by deadline: Duration) throws {
        try link.wait(by: deadline, until: { $0.status[status] == true }, missed: { .notReady(awaiting: status, said: $0.status) })
    }

    /// Brings one device up: sends its initialize request with `payload`, then waits for
    /// the daemon's word that the device is `ready`, in at most `limit` altogether. Both
    /// devices start this way and differ only in the three values, so the bringing up is
    /// one function of them. [LAW:one-type-per-behavior]
    func initialize(_ request: Request, _ payload: [UInt8], until ready: Status, within limit: Duration) throws -> Startup {
        let began = link.now()
        try self.request(request, payload, by: began + limit)
        // Taken here because `request` returns on the daemon's answer to it. Timing the
        // first frame of the readiness wait instead - as this did, and low-talker's spike
        // before it - reports the first status push under a name that says the daemon had
        // not spoken yet, when answering the request is exactly what it just did.
        let answered = link.now() - began
        try wait(for: ready, by: began + limit)
        return Startup(answered: answered, ready: link.now() - began)
    }

    /// The daemon's status payload, decoded: pairs of (status, value). Pure, and separate
    /// from recording for the reason the framing is - a transposed pair records the wrong
    /// status as true and nothing about that looks wrong at runtime. [LAW:decomposition]
    static func statusPairs(_ pairs: [UInt8]) throws -> [(Status, Bool)] {
        guard pairs.count % 2 == 0 else { throw DaemonError.malformed("a status payload of \(pairs.count) bytes, which is not pairs") }
        return try stride(from: 0, to: pairs.count, by: 2).map { index in
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
/// the fields below happens under it, but for `lastHeard`, which only the reader touches.
///
/// The socket is written by one thread too, the writer, from the outbox: every frame this
/// side sends waits its turn there, and goes out whole, so no two interleave. No caller
/// waits on the socket, only on the daemon's answer, so a peer that has stopped draining
/// holds no caller past its limit; the writer's patience is what finds that peer gone.
/// [LAW:single-enforcer] [LAW:no-ambient-temporal-coupling]
private final class Link: @unchecked Sendable {
    private let socket: Int32
    private let heartbeatInterval: Duration
    private let patience: Duration
    /// What request limits are kept on: offsets from the link's start.
    let now: @Sendable () -> Duration
    private let whenLost: @Sendable (DaemonError) -> Void
    private let guarded = NSCondition()
    private var nextRequestID: UInt64 = 1

    /// How far a request someone is waiting on has got.
    enum Progress {
        /// In the outbox, waiting its turn: nothing of it is on the wire.
        case queued
        /// Taken by the writer, and not yet all on the wire.
        case writing
        /// All on the wire, and not yet answered.
        case written
        case answered
    }

    /// Every request someone is still waiting on, and how far it has got.
    /// [LAW:one-source-of-truth] One table: an id is here while a waiter wants it and
    /// nowhere once it does not, and what a miss means is read from it, not inferred.
    var requests: [UInt64: Progress] = [:]
    var status: [DaemonConnection.Status: Bool] = [:]
    /// Every frame not yet taken by the writer, in the order they go out. A request's carries
    /// its id, so a limit that ends while it waits takes it back off, unsent.
    private var outbox: [(request: UInt64?, bytes: [UInt8])] = []
    /// When the daemon last sent a byte. Read and written by the reading thread alone, so
    /// it needs no lock: nothing else has a reason to know.
    ///
    /// On the clock that stops with the Mac: the silence that says anything about the
    /// daemon is silence while both were awake, and a clock that ran on through the lid
    /// being closed would find the daemon fifteen seconds gone the instant it opened.
    /// Request limits are kept on `now` instead: they are short, and a caller's.
    /// [LAW:no-ambient-temporal-coupling]
    private var lastHeard = SuspendingClock.now
    /// Set once, by whichever side ended the connection, and never cleared: every wait
    /// after it throws this, because the daemon cannot answer on a stream that is gone.
    private var failure: DaemonError?
    /// True when this side hung up, so the end of the stream that follows is not reported
    /// as the daemon's doing.
    private var hungUp = false

    init(socket: Int32, heartbeatEvery interval: Duration, patience: Duration, now: @escaping @Sendable () -> Duration, whenLost: @escaping @Sendable (DaemonError) -> Void) {
        self.socket = socket
        heartbeatInterval = interval
        self.patience = patience
        self.now = now
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

    /// Puts a request in the outbox and waits by `deadline` for the daemon's answer. The
    /// id is waited on before the frame can go out, so an answer that comes as the write
    /// ends finds it, and on every way out it is waited on no more, so a late answer is
    /// dropped at the door rather than kept for a collector that never comes. A connection
    /// already lost takes nothing in: no writer is left to send it.
    ///
    /// A miss is what the request's progress says it is. Still queued, it is taken back and
    /// is `.unsent`: nothing of it reached the daemon, and the connection goes on. Taken but
    /// not all written, the daemon is not taking what is written, `.writeStalled`. Written
    /// and unanswered, the daemon was `.silent`. Put in and waited on under one hold of the
    /// lock, so a limit spent at the call is always the first. [LAW:types-are-the-program]
    func ask(_ body: [UInt8], by deadline: Duration) throws {
        guarded.lock(); defer { guarded.unlock() }
        if let failure { throw failure }
        let id = nextRequestID
        nextRequestID += 1
        requests[id] = .queued
        defer { requests[id] = nil }
        outbox.append((id, Frame.request(id: id, payload: body).bytes))
        guarded.broadcast()
        if try waitHeld(by: deadline, until: { $0.requests[id] == .answered }) { return }
        switch requests[id] {
        case .queued?:
            outbox.removeAll { $0.request == id }
            throw DaemonError.unsent
        case .writing?: throw DaemonError.writeStalled
        case .written?: throw DaemonError.silent
        // Answered as the limit ended, which is no miss; and the id stays until this returns.
        case .answered?, nil: return
        }
    }

    /// Moves a request still waited on from one stage of its progress to the next. No one is
    /// woken: a waiter waits on the answer, and progress is read only at its miss. A waiter
    /// woken here could find its clock moved past the limit by a daemon whose answer is
    /// already on the wire, unread, and miss a request that was answered: the frames, read
    /// in order, are what wake it. [LAW:no-ambient-temporal-coupling]
    private func advance(_ id: UInt64?, from: Progress, to: Progress) {
        guard let id, requests[id] == from else { return }
        requests[id] = to
    }

    /// Blocks until `satisfied` holds, the connection has failed, or the deadline passes,
    /// in that order of precedence: an answer that arrived is an answer, even on a stream
    /// that ended just after it. [LAW:no-silent-failure] A daemon that says nothing is a
    /// named failure at the deadline, not a wait without end - named by `missed`, from what
    /// the link had heard by then.
    ///
    /// Every frame and every loss wakes it, and so does its own deadline, and each wake asks
    /// all three again, the deadline on `now`: a clock held still lets no deadline pass, and
    /// one moved past it is a miss at the next wake.
    func wait(by deadline: Duration, until satisfied: (Link) -> Bool, missed: (Link) -> DaemonError) throws {
        guarded.lock(); defer { guarded.unlock() }
        guard try waitHeld(by: deadline, until: satisfied) else { throw missed(self) }
    }

    /// `wait`, with the lock already held: true once `satisfied` holds, false at the
    /// deadline, and the failure thrown once there is one.
    private func waitHeld(by deadline: Duration, until satisfied: (Link) -> Bool) throws -> Bool {
        while true {
            if satisfied(self) { return true }
            if let failure { throw failure }
            let remaining = deadline - now()
            guard remaining > .zero else { return false }
            guarded.wait(until: Date(timeIntervalSinceNow: remaining.seconds))
        }
    }

    // MARK: Reading

    /// Reads until the stream ends, and writes until the connection does, each on a thread
    /// that holds this link and nothing else.
    func start() {
        run("DaemonConnection.reader") { try $0.readUntilTheEnd() }
        run("DaemonConnection.writer") { try $0.writeUntilTheEnd() }
    }

    /// One of the link's two threads; whatever ends it is the connection's loss.
    private func run(_ name: String, _ body: @escaping @Sendable (Link) throws -> Void) {
        let thread = Thread { [self] in
            do {
                try body(self)
            } catch {
                lost(error as? DaemonError ?? DaemonError.malformed("\(error)"))
            }
        }
        thread.name = name
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// The next thing to do is always the same: wait for the daemon, the heartbeat's turn
    /// or the end of the patience, whichever comes first, then do whichever came.
    /// [LAW:dataflow-not-control-flow]
    private func readUntilTheEnd() throws {
        var heartbeatDue = SuspendingClock.now + heartbeatInterval
        while true {
            let readable = try ready(POLLIN, by: min(heartbeatDue, lastHeard + patience))
            if SuspendingClock.now >= heartbeatDue {
                say(Frame.control(.heartbeat, payload: []))
                heartbeatDue += heartbeatInterval
            }
            if readable {
                try handle(try readFrame())
            }
            guard SuspendingClock.now < lastHeard + patience else { throw DaemonError.silent }
        }
    }

    /// What every frame means to this side: a pushed status is recorded and answered with
    /// an empty response, as pqrs's own client does; a health check is answered; a
    /// response's status pairs are recorded and its id is kept for whoever asked. The reply,
    /// where there is one, is written once what the frame said is recorded and its waiters
    /// woken.
    private func handle(_ frame: Frame) throws {
        let reply: Frame? = try {
            guarded.lock(); defer { guarded.unlock() }
            defer { guarded.broadcast() }
            switch frame {
            case .control(.healthCheck, _):
                return Frame.control(.healthCheckResponse, payload: [])
            case .control:
                return nil
            case .request(let id, let payload):
                try record(payload)
                return Frame.response(id: id, payload: [])
            case .response(let id, let payload):
                try record(payload)
                // Only a request still waited on: `nil` is not a key, so an answer to a
                // forgotten one records nothing. [LAW:dataflow-not-control-flow]
                requests[id] = requests[id].map { _ in .answered }
                return nil
            }
        }()
        reply.map(say)
    }

    /// What the reading thread sends - a heartbeat, an answer to the daemon - put in the
    /// outbox behind whatever is there, so the reading never waits on the socket's room.
    private func say(_ frame: Frame) {
        guarded.lock(); defer { guarded.unlock() }
        outbox.append((nil, frame.bytes))
        guarded.broadcast()
    }

    // MARK: Writing

    /// Writes each frame the outbox is given, in turn, until the connection ends, and
    /// keeps the progress of each request it writes.
    private func writeUntilTheEnd() throws(DaemonError) {
        while let next = nextOutgoing() {
            try write(next.bytes)
            guarded.lock()
            advance(next.request, from: .writing, to: .written)
            guarded.unlock()
        }
    }

    /// The oldest frame in the outbox, taken out once there is one, or nil once the
    /// connection has ended: nothing is written after the loss.
    private func nextOutgoing() -> (request: UInt64?, bytes: [UInt8])? {
        guarded.lock(); defer { guarded.unlock() }
        while outbox.isEmpty, failure == nil { guarded.wait() }
        guard failure == nil else { return nil }
        let next = outbox.removeFirst()
        advance(next.request, from: .queued, to: .writing)
        return next
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
    private func record(_ pairs: [UInt8]) throws {
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
        guarded.unlock()
        shutdown(socket, SHUT_RDWR)
    }

    /// The connection ended and this side did not end it: from the reader, the writer,
    /// or a frame the reader could not accept. The first loss is the failure every waiter
    /// throws from now on, every waiter is woken, and the owner is told - once, never for an
    /// end this side asked for, and after the lock is released, so an owner that answers by
    /// touching the connection cannot deadlock against this thread. [LAW:single-enforcer]
    ///
    /// The stream ends here for the daemon too. A loss this side declares - a status taken
    /// back, a version it was not built for, a silence - is on a socket the daemon still
    /// counts as a client, and it keeps that client's devices, and whatever is down on
    /// them, until the client goes: a mouse button held through a keyboard taken back
    /// stayed held. So a connection that has ended has ended on the wire, whoever still
    /// holds the object.
    private func lost(_ error: DaemonError) {
        guarded.lock()
        let owed = failure == nil && !hungUp
        failure = failure ?? error
        shutdown(socket, SHUT_RDWR)
        guarded.broadcast()
        guarded.unlock()
        if owed { whenLost(error) }
    }

    // MARK: The socket

    private func readFrame() throws -> Frame {
        let length = try Frame.bodyLength(header: read(4))
        return try Frame.decode(body: read(length))
    }

    /// Writes one frame whole, each chunk within the patience, like a read: a peer that
    /// stops draining without hanging up fills the kernel's buffer, and a connection whose
    /// writes stall is as gone as one whose reads do - named for the side it stalled on.
    private func write(_ bytes: [UInt8]) throws(DaemonError) {
        var offset = 0
        while offset < bytes.count {
            guard try ready(POLLOUT, by: SuspendingClock.now + patience) else { throw DaemonError.writeStalled }
            let written = uninterrupted { bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) } }
            // Room reported and gone again before the call: back to waiting for it.
            if written < 0, errno == EAGAIN { continue }
            guard written > 0 else { throw DaemonError.socket("write", errno) }
            offset += written
        }
    }

    /// Reads exactly `count` bytes, each chunk waited for within the patience: a peer that
    /// stops mid-frame is as gone as one that stops between frames.
    private func read(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            guard try ready(POLLIN, by: lastHeard + patience) else { throw DaemonError.silent }
            let got = uninterrupted { bytes[offset...].withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) } }
            if got < 0, errno == EAGAIN { continue }
            guard got > 0 else { throw got == 0 ? DaemonError.closed : DaemonError.socket("read", errno) }
            offset += got
            lastHeard = SuspendingClock.now
        }
        return bytes
    }

    /// Whether the socket is ready for `events` - something to read, or room to write - by
    /// `deadline`. The one wait on the socket, so the end of the stream, an interrupted
    /// call and a failed poll each have one reading. [LAW:single-enforcer]
    private func ready(_ events: Int32, by deadline: SuspendingClock.Instant) throws(DaemonError) -> Bool {
        while true {
            var descriptor = pollfd(fd: socket, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, max(0, (deadline - SuspendingClock.now).wholeMilliseconds))
            // Around the loop rather than retried in place, so the time actually left is
            // consulted again.
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw DaemonError.socket("poll", errno) }
            return ready > 0
        }
    }
}
