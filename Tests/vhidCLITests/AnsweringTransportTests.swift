import Foundation
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
        let (ended, end) = AsyncStream<Void>.makeStream()
        let session = Task {
            for try await _ in await transport.receive() { next.yield() }
            end.yield()
        }
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let answer = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        stdio.lines.yield(request)
        stdio.lines.yield(request)
        stdio.lines.finish()
        for await _ in read.prefix(2) {}
        try await transport.send(answer)
        let early = await Self.within(.milliseconds(200)) { () async -> Bool? in
            for await _ in ended { return true }
            return nil
        }
        #expect(early == nil, "the session ended with a request under id 1 unanswered")
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

    /// The result of `work`, or nil if it takes longer than `limit`.
    private static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
