import Foundation
import Installations
import MCP
import Pointing
import Testing
@testable import vhid

/// What the MCP server offers, and what it says to arguments it will not act on. No
/// daemon: every refusal here is one that comes back before a connection is made.
@Suite struct McpTests {
    /// A service nothing registers, so an argument that is wrongly let through fails to
    /// connect rather than moving the pointer of the Mac running the tests.
    static let nobody = Installation(service: "ai.promptctl.vhid.tests.nobody")!

    @Test func theSevenToolsAreListedInOrder() {
        #expect(Tools.all.map(\.tool.name) == ["type", "press", "click", "move", "scroll", "drag", "cursor"])
    }

    /// Only cursor promises to change nothing, because only cursor reaches no device.
    @Test func onlyCursorIsReadOnly() {
        #expect(Tools.all.filter { $0.tool.annotations.readOnlyHint == true }.map(\.tool.name) == ["cursor"])
    }

    // MARK: arguments

    private static func refusal(_ tool: VerbTool, _ given: [String: Value]) async -> String? {
        do {
            _ = try await tool.call(given, on: Self.nobody)
            return nil
        } catch let refused as ArgumentRefused {
            return refused.description
        } catch {
            return "not a refusal: \(error)"
        }
    }

    /// A misspelt argument is refused, not ignored: `times` for `count` would otherwise
    /// click once where three were asked for.
    @Test func anArgumentTheToolDoesNotTakeIsRefusedByName() async {
        #expect(await Self.refusal(Tools.click, ["x": 1, "y": 2, "times": 3])
            == "times is not an argument this tool takes: it takes x, y, button, count")
        #expect(await Self.refusal(Tools.cursor, ["x": 1]) == "x is not an argument this tool takes, and it takes none")
    }

    /// The same spellings the command line's `--button` refuses. [LAW:single-enforcer]
    @Test func aButtonTheReportHasNoBitForIsRefused() async {
        for button: Value in ["thumb", "0", "33", 0, 33, -1, 1.5, true] {
            let said = await Self.refusal(Tools.click, ["x": 1, "y": 2, "button": button])
            #expect(said?.hasPrefix("button is ") == true, "\(button) was not refused: \(said ?? "accepted")")
        }
    }

    @Test func noClicksIsRefused() async {
        #expect(await Self.refusal(Tools.click, ["x": 1, "y": 2, "count": 0])
            == "count is 0, and it is how many presses without moving between them, at least 1")
    }

    @Test func aMissingCoordinateIsNamed() async {
        #expect(await Self.refusal(Tools.move, ["x": 1])?.hasPrefix("y is missing") == true)
    }

    /// The SDK has already turned `data:,hi` into bytes it cannot give back as sent, when
    /// it read the JSON: the text arrives as it would from a client, decoded.
    @Test func textThatReadsAsADataURLIsRefused() async throws {
        let text = try JSONDecoder().decode(Value.self, from: Data(#""data:,hi""#.utf8))
        #expect(await Self.refusal(Tools.type, ["text": text])?.hasPrefix("text begins data:") == true)
    }

    @Test func aPlaceNeedsBothCoordinatesAndNothingElse() async {
        let from: Value = ["x": 1, "y": 2]
        #expect(await Self.refusal(Tools.drag, ["from": from, "to": ["x": 3]])?.hasPrefix("to is ") == true)
        #expect(await Self.refusal(Tools.drag, ["from": from, "to": ["x": 3, "y": 4, "z": 5]])?.hasPrefix("to is ") == true)
    }

    // MARK: a number a Double cannot hold

    private static func line(_ text: String) -> Data { Data(text.utf8) }

    /// Answered under the caller's own id, as a tool error naming the argument, so the
    /// call it belongs to ends and the model can read why.
    @Test func aNumberTooLargeIsAnsweredUnderTheCallersIdNamingTheArgument() throws {
        let answer = try #require(Unreadable.answer(to: Self.line(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"move","arguments":{"x":1e400,"y":10}}}"#)))
        let response = try JSONDecoder().decode(Response<CallTool>.self, from: answer)
        #expect(response.id == 7)
        let result = try response.result.get()
        #expect(result.isError == true)
        guard case .text(let said, _, _) = result.content.first else { Issue.record("no text in \(result)"); return }
        #expect(said == "x is a number too large for a Double to hold, so nothing was done")
    }

    @Test func everyArgumentTooLargeIsNamed() throws {
        let answer = try #require(Unreadable.answer(to: Self.line(
            #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"drag","arguments":{"from":{"x":1e400,"y":1},"to":{"x":1,"y":-1e999}}}}"#)))
        #expect(String(decoding: answer, as: UTF8.self).contains("from.x, to.y are numbers too large"))
    }

    @Test func aLineTheSDKCanReadIsLeftToIt() {
        #expect(Unreadable.answer(to: Self.line(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"move","arguments":{"x":1e300,"y":10}}}"#)) == nil)
        #expect(Unreadable.answer(to: Self.line(#"{"jsonrpc":"2.0","method":"notifications/x","params":{"n":1e400}}"#)) == nil)
    }

    // MARK: what is owed

    /// A request is owed an answer, an answer settles one, a cancellation withdraws one,
    /// and a notification is owed nothing.
    @Test func linesAreReadForWhatTheyAskAnswerAndWithdraw() {
        let request = Self.line(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"cursor"}}"#)
        let answer = Self.line(#"{"jsonrpc":"2.0","id":3,"result":{}}"#)
        let failure = Self.line(#"{"jsonrpc":"2.0","id":"b","error":{"code":-32602,"message":"no"}}"#)
        let cancel = Self.line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#)
        let notification = Self.line(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        #expect(Exchange.requested(in: request) == [3])
        #expect(Exchange.answered(in: request).isEmpty)
        #expect(Exchange.answered(in: answer) == [3])
        #expect(Exchange.answered(in: failure) == ["b"])
        #expect(Exchange.requested(in: answer).isEmpty)
        #expect(Exchange.withdrawn(in: cancel) == [3])
        #expect(Exchange.requested(in: cancel).isEmpty)
        #expect(Exchange.requested(in: notification).isEmpty)
        #expect(Exchange.withdrawn(in: request).isEmpty)
    }

    @Test func aBatchIsReadMessageByMessage() {
        let batch = Self.line(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":"two","method":"ping"}]"#)
        #expect(Exchange.requested(in: batch) == [1, "two"])
        #expect(Exchange.answered(in: Self.line(#"[{"jsonrpc":"2.0","id":1,"result":{}},{"jsonrpc":"2.0","id":"two","result":{}}]"#)) == [1, "two"])
    }

    /// One item the SDK cannot read fails the whole batch, which it then answers under an
    /// id of its own making. Owing the readable one would hold the session open for good.
    @Test func aBatchTheSDKCannotReadIsOwedNothing() {
        #expect(Exchange.requested(in: Self.line(#"[{"jsonrpc":"2.0","id":1,"method":"tools/list"},{"foo":1}]"#)).isEmpty)
        #expect(Exchange.requested(in: Self.line("[]")).isEmpty)
    }

    /// A response the client sends back, and a message with no jsonrpc version, are
    /// nothing the SDK answers.
    @Test func whatTheSDKDoesNotAnswerIsNotOwed() {
        #expect(Exchange.requested(in: Self.line(#"{"jsonrpc":"2.0","id":4,"result":{}}"#)).isEmpty)
        #expect(Exchange.requested(in: Self.line(#"{"jsonrpc":"2.0","id":[4],"method":"x"}"#)).isEmpty)
    }

    /// A request whose params are not an object is still owed: the SDK answers it with a
    /// parse error under the same id.
    @Test func aRequestOfAnUnexpectedShapeIsStillOwed() {
        #expect(Exchange.requested(in: Self.line(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":"x"}"#)) == [9])
        #expect(Exchange.requested(in: Self.line("not json")).isEmpty)
    }

    // MARK: turns

    /// Calls sent together run one after another, never report by report together: the
    /// daemon serves one client, and two calls at once would be two.
    @Test func callsTakeTurnsAndNeverOverlap() async throws {
        actor Record { var log: [String] = []; func note(_ s: String) { log.append(s) } }
        let turns = Turns(), record = Record()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in ["a", "b", "c"] {
                group.addTask {
                    try await turns.take {
                        await record.note("\(name) begins"); await Task.yield(); await record.note("\(name) ends")
                    }
                }
            }
            try await group.waitForAll()
        }
        let log = await record.log
        #expect(log.count == 6)
        for pair in stride(from: 0, to: log.count, by: 2) {
            #expect(log[pair].dropLast(7) == log[pair + 1].dropLast(5), "\(log) interleaves")
        }
    }

    /// A call whose caller is cancelled never runs, even behind one still running, and the
    /// turn after it still comes.
    @Test func aCancelledCallNeverRuns() async throws {
        let turns = Turns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let running = Task { try await turns.take { for await _ in gate { break } } }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await turns.take { "ran" }
        }
        open.yield()
        try await running.value
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await turns.take { "after" } == "after")
    }
}
