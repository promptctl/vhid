// Copied from Sources/vhid/AnsweringTransport.swift, not shared: the two packages link
// nothing of each other's (docs/development.md "Two packages"). A fix to one belongs in both. [LAW:one-way-deps]
import Foundation
import Logging
import MCP

/// A transport under which every request read is answered before the session ends.
///
/// It does that two ways: it answers, under the request's own id, every request the MCP
/// SDK cannot read, and it holds the stream of what was read open, past the end of stdin,
/// until every other request has been answered.
///
/// **Why it exists: a number JSON allows and a Double cannot hold.** `1e400` is valid
/// JSON. The SDK reads a request's arguments into its `Value`, which has no case for it,
/// so the whole request fails to decode. The SDK then answers with a parse error under a
/// *random* id, because it could not read the id either. A client waiting on its own id
/// never matches that answer, so its tool call hangs until it times out, and nothing
/// says which argument did it. Measured against 0.12.1: the answer to a `move` whose x is
/// `1e400`, sent as id 7, came back as a parse error under a random UUID.
/// [LAW:no-silent-failure]
///
/// Nothing reaches a device either way. What this adds is an answer the caller can read:
/// a tool call gets a tool error naming the argument, which the MCP spec says an input
/// error should be so that the model can see it. Any other request gets `invalidParams`.
///
/// **Why it holds the stream open: the SDK does not wait for its own answers.** It runs
/// each request in a task of its own, and a session is over when the stream of what was
/// read ends. So a client that writes its calls and closes stdin, as a shell pipe does,
/// got the process exiting under calls still running: 2 or 3 of 13 answers never came,
/// measured, and a call cut off partway had done part of what it was asked, with nothing
/// said. [LAW:no-ambient-temporal-coupling] What is still owed is a count per id this actor
/// keeps, and the end of stdin waits on it being empty, unless the session is stopped.
///
/// **Why it withdraws calls itself: the SDK's cancel loses answers.** The SDK answers a
/// cancelled request with nothing, and its cancel reaches a handler or not by the luck of
/// when it is read: before the handler's task is registered it is ignored, and the call
/// runs on and is answered; after, the call ends unanswered. Either way nothing tells this
/// transport which, so an id settled at its cancel let a pipe that sent a call, its cancel,
/// and the end of stdin have the process exit under a click still running. So a cancel
/// never reaches the SDK. The transport stops the handler for that id itself, the handler
/// answers as every handler does, and that answer settles the id and is dropped rather
/// than written, as the MCP spec says a cancelled request's must be. Every request read is
/// answered exactly once, and `owed` is the one ledger of what the session waits on.
/// [LAW:one-source-of-truth] The SDK does not tell a handler its request's id, except
/// through the per-request context it asks its transport for; that is where this one
/// hands the id over.
///
/// [LAW:effects-at-boundaries] The deciding is `Unreadable.answer(to:)` and `Exchange`,
/// pure functions of a line. This actor only moves bytes and keeps the count.
actor AnsweringTransport: Transport, HTTPContextProviding {
    private let inner: any Transport
    /// How many requests read under each id are not yet answered. A count, not a set: a
    /// client may reuse an id while its first request is in flight, and each is answered.
    /// [LAW:types-are-the-program]
    private var owed: [ID: Int] = [:]
    /// How many answers under each id were withdrawn, and so are dropped when they come.
    private var withdrawn: [ID: Int] = [:]
    /// What stops each handler running, by the id it answers.
    private var running: [ID: [UUID: @Sendable () -> Void]] = [:]
    /// Resumed when nothing is owed, by whichever end comes last. Keyed by waiter, so a
    /// stopped relay lets go of its own wait and no other.
    private var settled: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Diagnostics go to stderr, which is the only place they may: stdout is the protocol's.
    nonisolated let logger: Logger

    init(_ inner: any Transport, logger: Logger = Logger(label: "eyes.mcp", factory: { StreamLogHandler.standardError(label: $0) })) {
        self.inner = inner
        self.logger = logger
    }

    func connect() async throws { try await inner.connect() }
    func disconnect() async { await inner.disconnect() }
    /// An answer is crossed off before it is written: one whose write fails is one stdout
    /// can no longer carry, and waiting on it would hold the session open for nothing.
    func send(_ data: Data) async throws {
        let ids = Exchange.answered(in: data)
        let dropped = ids.filter(takeWithdrawn)
        settle(ids)
        // A withdrawn call can have done all it was asked before its withdrawal was read,
        // and its answer is then the one report of it. [LAW:no-silent-failure]
        for id in dropped { logger.notice("answer to a withdrawn call not written", metadata: ["id": "\(id)", "answer": "\(String(decoding: data, as: UTF8.self))"]) }
        // Written unless every id it answers was withdrawn: a batch answering anything else
        // goes whole, since a response cannot be cut out of it without rewriting the line.
        if ids.isEmpty || dropped.count < ids.count { try await inner.send(data) }
    }

    /// The id a handler answers, handed to it by the SDK as its request's context.
    func httpRequestContext(for id: ID) -> HTTPRequest? {
        HTTPRequest(method: "", headers: [Self.idHeader: String(decoding: try! JSONEncoder().encode(id), as: UTF8.self)])
    }

    private static let idHeader = "json-rpc-id"

    /// Whether the session is being stopped from outside, so that every call read from
    /// now on is withdrawn as it is owed: one read in the moment between the stop and the
    /// SDK's loop ending would otherwise run as if nobody had asked it to stop.
    private var stopping = false

    private func owe(_ line: Data) {
        let ids = Exchange.requested(in: line)
        for id in ids { owed[id, default: 0] += 1 }
        if stopping { withdraw(ids) }
    }

    /// A withdrawn call is stopped now if its handler is running, and when it starts if not.
    private func withdraw(_ ids: [ID]) {
        // No more withdrawn under an id than are owed under it, so a cancel sent twice
        // cannot drop the answer to a later call that reuses the id.
        for id in ids where withdrawn[id, default: 0] < owed[id, default: 0] {
            withdrawn[id, default: 0] += 1
            running[id]?.values.forEach { $0() }
        }
    }

    /// Withdraws every call owed, running or not yet started, and every call read after
    /// it: the session is being stopped from outside, and its calls stop with it.
    func withdrawEverything() {
        stopping = true
        withdraw(owed.flatMap { id, count in Array(repeating: id, count: count) })
    }

    private func takeWithdrawn(_ id: ID) -> Bool {
        guard let count = withdrawn[id] else { return false }
        withdrawn[id] = count > 1 ? count - 1 : nil
        return true
    }

    private func settle(_ ids: [ID]) {
        for id in ids {
            owed[id] = owed[id].flatMap { $0 > 1 ? $0 - 1 : nil }
            withdrawn[id] = withdrawn[id].flatMap { min($0, owed[id] ?? 0) }.flatMap { $0 > 0 ? $0 : nil }
        }
        if owed.isEmpty { release() }
    }

    /// Runs a handler's `work` where a withdrawal of its call can stop it. What `work` says
    /// once stopped is its answer, which the transport drops, so it must not throw a
    /// cancellation: the SDK answers that with nothing, and the session would wait for good.
    nonisolated func underway<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let header = Server.currentHandlerContext?.httpContext?.header(Self.idHeader),
              let id = try? JSONDecoder().decode(ID.self, from: Data(header.utf8)) else {
            throw MCPError.internalError("a handler ran without the id of the request it answers")
        }
        // Enrolled before `work` may start, so a call withdrawn already starts cancelled
        // and sends nothing, rather than running until its withdrawal catches up with it.
        let (enrolled, open) = AsyncStream<Void>.makeStream()
        let job = Task {
            for await _ in enrolled {}
            return try await work()
        }
        let key = UUID()
        await enroll(id, key) { job.cancel() }
        open.finish()
        let outcome: Result<T, any Error>
        do { outcome = .success(try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }) } catch { outcome = .failure(error) }
        await leave(id, key)
        return try outcome.get()
    }

    private func enroll(_ id: ID, _ key: UUID, stop: @escaping @Sendable () -> Void) {
        if withdrawn[id] != nil { stop() }
        running[id, default: [:]][key] = stop
    }

    private func leave(_ id: ID, _ key: UUID) {
        running[id]?[key] = nil
        if running[id]?.isEmpty == true { running[id] = nil }
    }

    private func release() {
        settled.values.forEach { $0.resume() }
        settled = [:]
    }

    private func release(_ waiter: UUID) {
        settled.removeValue(forKey: waiter)?.resume()
    }

    /// Whether a relay is parked, waiting on what is owed.
    var isWaiting: Bool { !settled.isEmpty }

    /// How many requests read under `id` are not yet answered.
    func owing(_ id: ID) -> Int { owed[id] ?? 0 }

    /// How many of those were withdrawn, and so will not be written.
    func withdrawing(_ id: ID) -> Int { withdrawn[id] ?? 0 }

    /// Returns once nothing is owed, or once the wait is cancelled: a session stopped from
    /// inside, as `server.stop` does, will never send the answers it would be waiting on.
    /// What it gives up on is said, by id. [LAW:no-silent-failure]
    private func everythingAnswered() async {
        if !owed.isEmpty { logger.info("stdin ended, waiting on answers owed", metadata: ["owed": owedNow]) }
        let waiter = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if owed.isEmpty || Task.isCancelled { continuation.resume() } else { settled[waiter] = continuation }
            }
        } onCancel: {
            Task { await self.release(waiter) }
        }
        if !owed.isEmpty { logger.warning("session stopped with answers owed", metadata: ["owed": owedNow]) }
    }

    /// What is owed, as one line a person can read: each id as JSON writes it, so `7` and
    /// `"7"` stay two ids, with its count and how many of those were withdrawn, in a fixed order.
    private var owedNow: Logger.MetadataValue {
        .string(owed.map { id, count in
            let name = switch id {
            case .string(let text): "\"\(text)\""
            case .number(let number): "\(number)"
            }
            return "\(name)×\(count)" + (withdrawn[id].map { " (\($0) withdrawn)" } ?? "")
        }.sorted().joined(separator: ", "))
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        let inner = inner
        return AsyncThrowingStream { continuation in
            let relay = Task {
                do {
                    for try await line in await inner.receive() {
                        if let answer = Unreadable.answer(to: line) {
                            try await inner.send(answer)
                        } else {
                            // Owed before the SDK sees it, so its answer cannot come first.
                            // A withdrawal is the transport's to carry out, never the SDK's.
                            let withdrawn = Exchange.withdrawn(in: line)
                            await self.owe(line)
                            await self.withdraw(withdrawn)
                            if withdrawn.isEmpty { continuation.yield(line) }
                        }
                    }
                    await self.everythingAnswered()
                    continuation.finish()
                } catch {
                    await self.everythingAnswered()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}

/// A request that JSON can carry and the SDK's `Value` cannot, and what to say back.
enum Unreadable {
    /// The answer to `line`, or nil for a line the SDK can read, or one with no id to
    /// answer under. A line with no id is a notification or not JSON-RPC at all. The SDK
    /// already says what can be said about those.
    static func answer(to line: Data) -> Data? {
        let decoder = JSONDecoder()
        guard (try? decoder.decode(Value.self, from: line)) == nil,
              let request = try? decoder.decode(Request.self, from: line) else { return nil }
        let names = request.params?.unreadable(at: []).map { $0.joined(separator: ".") } ?? []
        let said = "\(names.isEmpty ? "a value" : names.joined(separator: ", ")) \(names.count > 1 ? "are numbers" : "is a number") too large for a Double to hold, so nothing was done"
        // The error is typed as a tool call's too: an error response carries no result,
        // so which method it names makes no difference on the wire.
        let response = request.method == CallTool.name
            ? CallTool.response(id: request.id, result: .init(content: [.text(text: said, annotations: nil, _meta: nil)], isError: true))
            : CallTool.response(id: request.id, error: .invalidParams(said))
        // [LAW:no-silent-failure] A response made of strings and an id always encodes. If
        // it ever did not, the line goes on to the SDK, whose parse error is what a caller
        // got before this existed: late, but still an error.
        return try? JSONEncoder().encode(response)
    }

    /// Just enough of a request to answer it. `params` is read as a `Probe`, which
    /// accepts every JSON value, so the one thing that cannot be read is found rather
    /// than failed on.
    private struct Request: Decodable {
        let id: ID
        let method: String
        let params: Probe?
    }

    /// A JSON value read only as far as whether the SDK could read it.
    private enum Probe: Decodable {
        case readable
        case object([String: Probe])
        case array([Probe])
        case unreadable

        init(from decoder: any Decoder) throws {
            self = if (try? Value(from: decoder)) != nil { .readable }
                else if let object = try? [String: Probe](from: decoder) { .object(object) }
                else if let array = try? [Probe](from: decoder) { .array(array) }
                else { .unreadable }
        }

        /// The paths to every unreadable value under this one. A tool call's arguments
        /// are named as the tool names them, `x` rather than `arguments.x`.
        func unreadable(at path: [String]) -> [[String]] {
            switch self {
            case .readable: []
            case .unreadable: [path.first == "arguments" ? Array(path.dropFirst()) : path]
            case .object(let fields): fields.sorted { $0.key < $1.key }.flatMap { $0.value.unreadable(at: path + [$0.key]) }
            case .array(let items): items.enumerated().flatMap { $0.element.unreadable(at: path + ["\($0.offset)"]) }
            }
        }
    }
}

/// Which requests a line asks, answers, or withdraws, by id.
///
/// [LAW:one-source-of-truth] Owed means the SDK will answer it, and only the SDK knows
/// which lines those are. So each message is read by the SDK's own decoders, through a
/// method and a notification whose parameters are any `Value` - what its internal
/// `AnyMethod` and `AnyNotification` are - and in the order its receive loop tries them.
/// A reading looser than the SDK's would owe an answer it never sends, and the session
/// would wait on it for good.
enum Exchange {
    /// The ids the SDK will answer for this line, read from the client.
    static func requested(in line: Data) -> [ID] {
        if let items = try? decoder.decode([Value].self, from: line) {
            // A batch is answered only when every item in it is read; one that is not
            // fails the whole batch, which the SDK answers under an id of its own making.
            var ids: [ID] = []
            for item in items {
                guard let data = try? encoder.encode(item), let fields = item.objectValue else { return [] }
                if fields["id"] != nil {
                    guard let request = try? decoder.decode(Request<Asked>.self, from: data) else { return [] }
                    ids.append(request.id)
                } else {
                    guard (try? decoder.decode(Message<Told>.self, from: data)) != nil else { return [] }
                }
            }
            return ids
        }
        if (try? decoder.decode(Response<Asked>.self, from: line)) != nil { return [] }
        if let request = try? decoder.decode(Request<Asked>.self, from: line) { return [request.id] }
        if (try? decoder.decode(Message<Told>.self, from: line)) != nil { return [] }
        // What none of those read, the SDK answers as a parse error under the line's own
        // id when it can find a string or a whole number there, and under a random one
        // when it cannot.
        guard let id = (try? decoder.decode([String: Value].self, from: line))?["id"] else { return [] }
        if let text = id.stringValue { return [.string(text)] }
        if let number = id.intValue { return [.number(number)] }
        return []
    }

    /// The ids this line, written by the server, answers: one response or a batch of them.
    static func answered(in data: Data) -> [ID] {
        if let one = try? decoder.decode(Response<Asked>.self, from: data) { return [one.id] }
        return ((try? decoder.decode([Response<Asked>].self, from: data)) ?? []).map(\.id)
    }

    /// The request this line, read from the client, withdraws.
    static func withdrawn(in line: Data) -> [ID] {
        guard let cancel = try? decoder.decode(Message<CancelledNotification>.self, from: line),
              cancel.method == CancelledNotification.name, let id = cancel.params.requestId else { return [] }
        return [id]
    }

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    /// Any request, read as the SDK reads one it has not yet matched to a handler.
    private struct Asked: MCP.Method {
        static let name = ""
        typealias Parameters = Value
        typealias Result = Value
    }

    /// Any notification, likewise.
    private struct Told: MCP.Notification {
        static let name = ""
        typealias Parameters = Value
    }
}
