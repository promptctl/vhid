import Foundation
import Installations
import Logging
import MCP
import Testing
@testable import vhid

/// What the transport holds the session open for, driven through a stand-in for stdio.
@Suite struct AnsweringTransportTests {
    /// Two requests in flight under one id are two answers owed: the first settles one,
    /// and the end of stdin still waits on the other.
    @Test func aReusedIdIsOwedOnceForEachRequest() async throws {
        let stdio = Stdio(), transport = AnsweringTransport(stdio)
        let (read, next) = AsyncStream<Void>.makeStream()
        let session = Task {
            for try await _ in await transport.receive() { next.yield() }
        }
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let answer = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        stdio.lines.yield(request)
        stdio.lines.yield(request)
        stdio.lines.finish()
        for await _ in read.prefix(2) {}
        #expect(await transport.owing(1) == 2)
        try await transport.send(answer)
        #expect(await transport.owing(1) == 1, "the first answer settled both requests under id 1")
        try await transport.send(answer)
        try await session.value
    }

    /// A session stopped while an answer is owed lets go of its transport rather than
    /// waiting on an answer nothing will now send.
    @Test func aStoppedSessionDoesNotWaitOnWhatIsOwed() async throws {
        let stdio = Stdio()
        weak var held: AnsweringTransport?
        do {
            let transport = AnsweringTransport(stdio)
            held = transport
            let (read, next) = AsyncStream<Void>.makeStream()
            let session = Task {
                for try await _ in await transport.receive() { next.yield() }
            }
            stdio.lines.yield(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
            for await _ in read { break }
            session.cancel()
            _ = try? await session.value
        }
        for _ in 0..<200 where held != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(held == nil, "the relay is still waiting on the owed answer")
    }

    /// Stopped after stdin has ended, when the relay is already parked on what is owed, the
    /// session still ends, and says which answers it gave up on.
    @Test func aSessionStoppedWhileParkedEndsAndSaysWhatWasOwed() async throws {
        let stdio = Stdio(), said = Said()
        let transport = AnsweringTransport(stdio, logger: Logger(label: "test") { _ in said })
        let (read, next) = AsyncStream<Void>.makeStream()
        let session = Task {
            for try await _ in await transport.receive() { next.yield() }
        }
        stdio.lines.yield(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8))
        stdio.lines.yield(Data(#"{"jsonrpc":"2.0","id":"7","method":"tools/list"}"#.utf8))
        stdio.lines.finish()
        for await _ in read.prefix(2) {}
        // Parked: the only thing left for the relay to do is wait on id 7.
        for _ in 0..<200 where !(await transport.isWaiting) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await transport.isWaiting)
        session.cancel()
        _ = try? await session.value
        for _ in 0..<200 where said.lines.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(said.lines == [
            #"stdin ended, waiting on answers owed owed="7"×1, 7×1"#,
            #"session stopped with answers owed owed="7"×1, 7×1"#,
        ])
    }

    /// A withdrawn call whose handler pays the withdrawal no mind holds the end of stdin
    /// until its handler is over, and its answer is never written.
    @Test func aWithdrawnCallHoldsTheSessionUntilItsHandlerIsOver() async throws {
        let (finish, done) = AsyncStream<Void>.makeStream()
        let (began, begin) = AsyncStream<Void>.makeStream()
        let stubborn = VerbTool(Help.click, []) { _, _ in
            // A task of its own, so the withdrawal cannot reach it.
            await Task {
                begin.yield()
                for await _ in finish {}
                return "clicked"
            }.value
        }
        let stdio = Stdio(), said = Said()
        let transport = AnsweringTransport(stdio, logger: Logger(label: "test") { _ in said })
        let session = Task {
            let server = await McpCommand.server([stubborn], on: Installation(service: "ai.promptctl.vhid.tests.nobody")!, over: transport)
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        }
        stdio.call(3, then: [])
        for await _ in began { break }
        stdio.feed([.cancel(3), .end])
        for _ in 0..<200 where !(await transport.isWaiting) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await transport.isWaiting, "the session ended under a handler still running")
        #expect(said.lines.filter { $0.hasPrefix("stdin ended") } == ["stdin ended, waiting on answers owed owed=3×1 (1 withdrawn)"])
        done.finish()
        try await session.value
        #expect(stdio.sent.isEmpty, "a withdrawn call's answer was written: \(stdio.sent)")
    }

    /// A call withdrawn in the same breath as it was asked, before its handler could have
    /// started, still ends the session once it is over, and answers nothing. The SDK, had it
    /// read the cancel, would have answered nothing and left the session waiting for good,
    /// or ignored it and let the call run on unawaited.
    @Test func aCallWithdrawnAsItIsAskedEndsTheSessionWithNoAnswer() async throws {
        let waiting = VerbTool(Help.click, []) { _, _ in
            try await Task.sleep(for: .seconds(3600))
            return "clicked"
        }
        let stdio = Stdio(), transport = AnsweringTransport(stdio)
        let session = Task {
            let server = await McpCommand.server([waiting], on: Installation(service: "ai.promptctl.vhid.tests.nobody")!, over: transport)
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        }
        stdio.call(4, then: [.cancel(4), .end])
        let ended = await withTaskGroup(of: Bool.self) { race in
            race.addTask { _ = try? await session.value; return true }
            race.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            defer { race.cancelAll() }
            return await race.next() ?? false
        }
        #expect(ended, "the session is still waiting on a withdrawn call")
        #expect(stdio.sent.isEmpty, "a withdrawn call's answer was written: \(stdio.sent)")
    }
}

/// What a transport logged, one line per message with its metadata.
private final class Said: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []
    var lines: [String] { lock.withLock { kept } }
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] } set { metadata[key] = newValue }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        let fields = (metadata ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        lock.withLock { kept.append(([message.description] + fields).joined(separator: " ")) }
    }
}

/// Stdio as a test drives it: lines are fed in by hand, and what is sent is kept.
private actor Stdio: Transport {
    nonisolated let logger = Logger(label: "test")
    nonisolated let (stream, lines) = AsyncThrowingStream<Data, any Error>.makeStream()
    private nonisolated let kept = Kept()
    nonisolated var sent: [String] { kept.lines }
    func connect() async throws {}
    func disconnect() async {}
    func send(_ data: Data) async throws { kept.append(String(decoding: data, as: UTF8.self)) }
    func receive() -> AsyncThrowingStream<Data, any Error> { stream }

    enum Line { case cancel(Int), end }

    /// A tool call under `id` naming `click`, then `rest`, all in one go.
    nonisolated func call(_ id: Int, then rest: [Line]) {
        lines.yield(Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"click"}}"#.utf8))
        feed(rest)
    }

    nonisolated func feed(_ rest: [Line]) {
        for line in rest {
            switch line {
            case .cancel(let id): lines.yield(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id)}}"#.utf8))
            case .end: lines.finish()
            }
        }
    }
}

private final class Kept: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []
    var lines: [String] { lock.withLock { kept } }
    func append(_ line: String) { lock.withLock { kept.append(line) } }
}
