import EyesVerbs
import Foundation
import Installations
import Seeing
import Telemetry
import TelemetryTesting
import Testing
@testable import vhid
import ScreenSpace

/// The `look` tool as `vhid mcp` serves it, on a screen a test wrote: one record of each
/// call, and no wait behind the daemon. [LAW:behavior-not-structure]
@Suite(.eventsKept) struct LookToolTests {
    static let main = Display(id: 1, frame: ScreenRect(x: 0, y: 0, width: 1512, height: 982)!, isMain: true, scale: 2)
    static let safari = Front.App(pid: 400, name: "Safari")
    static let desk = Desk(frontmost: safari, own: Front.Passed(pids: [80], name: "iTerm2"),
                           running: [Desk.Running(app: safari, regular: true)],
                           listing: WindowListing(windows: [Window(id: 4, owner: "Safari", pid: 400, frame: ScreenRect(x: 0, y: 40, width: 600, height: 400)!, layer: 0)],
                                                  excluded: []),
                           displays: [main])
    static let screen = Screen(desk: { desk }) { _, _ in
        Judged(Reading(outcome: .nearest([]), scope: Scope(region: main.frame, examined: 0, reach: .whole))) { r, _ in r }
    }

    /// The done criterion: one look is one call record, and the look's own units - choosing
    /// the app, reading it, the overview round them - are nested under it on its one trace.
    @Test func oneLookLeavesOneCallRecordWithItsUnitsNestedUnderIt() async throws {
        let collected = Collected(), stdio = Stdio()
        try await Telemetry.$export.withValue(collected.export) {
            stdio.call(1, "look", then: [.end])
            try await McpCommand.serve([Tools.look(on: Self.screen)], on: .nobody, over: AnsweringTransport(stdio))
        }
        let records = collected.all
        let calls = records.filter { $0.parentSpanID == nil }
        try #require(calls.count == 1, "\(records.map(\.event))")
        let call = calls[0]
        #expect(call.event == "look" && call.attributes["entry"] == "mcp" && call.outcome == .ok)
        #expect(Set(records.map(\.event)) == ["look", "overview", "front", "reading"])
        #expect(records.allSatisfy { $0.traceID == call.traceID })
        let spans = Set(records.map(\.spanID))
        #expect(records.allSatisfy { $0.parentSpanID.map(spans.contains) ?? true })
        // A look takes no turn, so it waited behind nothing to say.
        #expect(call.counts["queued_ms"] == nil)
        #expect(stdio.sent.contains { $0.contains("1 display, main first") && $0.contains("Safari (pid 400) and what is in front of it") })
    }

    /// The done criterion: a look sent beside a click that holds the daemon's turn is
    /// answered while the click is still underway.
    @Test(.timeLimit(.minutes(1))) func aLookIsAnsweredWhileAClickHoldsTheDaemonsTurn() async throws {
        let (began, begin) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let click = VerbTool(Help.click, []) { _, _ in
            begin.yield()
            for await _ in released { break }
            return "clicked"
        }
        let stdio = Stdio()
        let session = Task {
            try await McpCommand.serve([click, Tools.look(on: Self.screen)], on: .nobody, over: AnsweringTransport(stdio))
        }
        stdio.call(1, then: [])
        for await _ in began { break }
        stdio.call(2, "look", then: [])
        _ = await stdio.answer(to: 2)
        #expect(!stdio.sent.contains { Stdio.answers($0, 1) }, "the click answered before it was let go")
        release.yield()
        stdio.feed([.end])
        try await session.value
        #expect(stdio.sent.contains { Stdio.answers($0, 1) && $0.contains("clicked") })
    }
}
