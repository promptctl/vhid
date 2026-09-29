// Copied from Tests/vhidCLITests/AnsweringTransportTests.swift, as the transport it tests
// is. A fix to one belongs in both. [LAW:one-way-deps]
import Foundation
import Logging
import MCP
import Testing
@testable import EyesCommand

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
            #"stdin ended, waiting on answers owed and calls running owed="7"×1, 7×1 running=0"#,
            #"session stopped with answers owed or calls running owed="7"×1, 7×1 running=0"#,
        ])
    }

    /// A withdrawn call is owed no answer, but a handler still running it holds the end of
    /// stdin until it is over: the SDK's cancel only asks the handler to stop.
    @Test func aWithdrawnCallStillRunningHoldsTheSession() async throws {
        let stdio = Stdio(), transport = AnsweringTransport(stdio)
        let (read, next) = AsyncStream<Void>.makeStream()
        let session = Task {
            for try await _ in await transport.receive() { next.yield() }
        }
        let (started, begun) = AsyncStream<Void>.makeStream()
        let (finish, done) = AsyncStream<Void>.makeStream()
        let handler = Task {
            try await transport.underway {
                begun.yield()
                for await _ in finish {}
            }
        }
        for await _ in started { break }
        stdio.lines.yield(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click"}}"#.utf8))
        stdio.lines.yield(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#.utf8))
        stdio.lines.finish()
        for await _ in read.prefix(1) {}
        for _ in 0..<200 where !(await transport.isWaiting) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await transport.owing(3) == 0)
        #expect(await transport.isWaiting, "the session ended under a handler still running")
        done.finish()
        try await handler.value
        try await session.value
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

/// Stdio as a test drives it: lines are fed in by hand, and what is sent is dropped.
private actor Stdio: Transport {
    nonisolated let logger = Logger(label: "test")
    nonisolated let (stream, lines) = AsyncThrowingStream<Data, any Error>.makeStream()
    func connect() async throws {}
    func disconnect() async {}
    func send(_ data: Data) async throws {}
    func receive() -> AsyncThrowingStream<Data, any Error> { stream }
}
