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
/// said. [LAW:no-ambient-temporal-coupling] What is still owed is a set this actor keeps,
/// and the end of stdin waits on it being empty.
///
/// [LAW:effects-at-boundaries] The deciding is `Unreadable.answer(to:)` and `Exchange`,
/// pure functions of a line. This actor only moves bytes and keeps the count.
actor AnsweringTransport: Transport {
    private let inner: any Transport
    /// The ids of requests read and not yet answered.
    private var owed: Set<ID> = []
    /// Resumed when nothing is owed, by whichever answer settles the last of it.
    private var settled: [CheckedContinuation<Void, Never>] = []

    /// Diagnostics go to stderr, which is the only place they may: stdout is the protocol's.
    nonisolated let logger = Logger(label: "vhid.mcp", factory: { StreamLogHandler.standardError(label: $0) })

    init(_ inner: any Transport) {
        self.inner = inner
    }

    func connect() async throws { try await inner.connect() }
    func disconnect() async { await inner.disconnect() }
    /// An answer is crossed off before it is written: one whose write fails is one stdout
    /// can no longer carry, and waiting on it would hold the session open for nothing.
    func send(_ data: Data) async throws {
        settle(Exchange.answered(in: data))
        try await inner.send(data)
    }

    private func owe(_ line: Data) {
        owed.formUnion(Exchange.requested(in: line))
        settle(Exchange.withdrawn(in: line))
    }

    private func settle(_ ids: [ID]) {
        owed.subtract(ids)
        guard owed.isEmpty else { return }
        settled.forEach { $0.resume() }
        settled = []
    }

    private func everythingAnswered() async {
        if owed.isEmpty { return }
        await withCheckedContinuation { settled.append($0) }
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
                            await self.owe(line)
                            continuation.yield(line)
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
/// A line is one JSON-RPC message or a batch of them. A request carries an id and a method;
/// an answer carries an id and no method. A cancellation withdraws the request it names,
/// which the SDK then answers with nothing at all, as the MCP spec says it must.
enum Exchange {
    static func requested(in line: Data) -> [ID] {
        messages(in: line).compactMap { $0.method == nil ? nil : $0.id }
    }

    static func answered(in data: Data) -> [ID] {
        messages(in: data).compactMap { $0.method == nil ? $0.id : nil }
    }

    static func withdrawn(in line: Data) -> [ID] {
        messages(in: line).compactMap { $0.method == CancelledNotification.name ? $0.params?.requestId : nil }
    }

    private static func messages(in data: Data) -> [Envelope] {
        let decoder = JSONDecoder()
        if let one = try? decoder.decode(Envelope.self, from: data) { return [one] }
        return (try? decoder.decode([Envelope].self, from: data)) ?? []
    }

    /// A message read no further than what this needs. Each field is read on its own, so
    /// one of an unexpected shape costs that field and not the message.
    private struct Envelope: Decodable {
        let id: ID?
        let method: String?
        let params: Withdrawal?

        private enum CodingKeys: String, CodingKey { case id, method, params }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try? fields.decodeIfPresent(ID.self, forKey: .id)
            method = try? fields.decodeIfPresent(String.self, forKey: .method)
            params = try? fields.decodeIfPresent(Withdrawal.self, forKey: .params)
        }
    }

    private struct Withdrawal: Decodable {
        let requestId: ID?
    }
}
