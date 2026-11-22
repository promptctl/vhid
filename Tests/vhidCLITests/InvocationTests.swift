import ChildProcess
import struct EyesVerbs.ArgumentRefused
import struct EyesVerbs.Entry
import ArgumentParser
import DriverExtension
import Foundation
@testable import Helper
import Input
import Installations
import OwnThread
import Signals
import Synchronization
import Telemetry
import TelemetryTesting
import TestClock
import Testing
@testable import vhid
import ScreenSpace
import ScreenSpaceTesting
import InputTesting

/// Every invocation leaves one record, however it ends, and the record carries what the
/// verb decided. Driven through `Devices.using` over a real XPC connection to a far end of
/// the test's own, because that is where the reports are counted. [LAW:behavior-not-structure]
@Suite(.eventsKept) struct InvocationTests {
    static let at = ScreenPoint.at(40, 30)

    /// `body` against a far end that acknowledges every act until `after` of them.
    private static func against<T: Sendable>(acknowledging after: Int = .max, _ body: (Devices) async throws -> T) async throws -> T {
        let service = UnreachableTests.Service(.refusing(after: after, refusal: UnreachableTests.devicesDown))
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let helper = HelperConnection(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), service: UnreachableTests.far, replyTimeout: .seconds(20))
        return try await Devices.using(helper, body)
    }

    private static func scroll(vertical: Int, horizontal: Int, clock: ManualClock = ManualClock(), on devices: Devices) async throws -> String {
        try await ScrollCommand.scroll(at: .point(at), vertical: vertical, horizontal: horizontal, holding: .none,
                                       with: Pointer(mouse: devices.mouse, cursor: { at }, clock: clock, randomness: RandomSource(seed: 1), hand: .macOSDefault, traced: devices.trail.traced), devices.keyboard)
    }

    private static func only(_ collected: Collected) throws -> [String: Any] {
        let written = try collected.written
        try #require(written.count == 1, "\(written)")
        return written[0]
    }

    /// `body` run as the command line runs a verb, its record kept in `collected`.
    private static func cli<T>(_ event: String, into collected: Collected, _ body: () async throws -> T) async throws -> T {
        try await Telemetry.$export.withValue(collected.export) { try await Vhid.dispatched(event, body) }
    }

    /// `body` run as the MCP server runs a call, its record kept in `collected`.
    private static func mcp<T>(_ name: String, into collected: Collected, _ body: () async throws -> T) async throws -> T {
        try await Telemetry.$export.withValue(collected.export) { try await McpCommand.dispatched(name, stoppedBy: nil, body) }
    }

    /// A scroll of nothing reached the devices and sent nothing, and says so in zeros;
    /// no invocation at all writes nothing.
    @Test func aVerbThatDidNothingIsRecordedAsZerosAndNoInvocationIsNotRecorded() async throws {
        let collected = Collected()
        #expect(try collected.written.isEmpty)
        _ = try await Self.cli("scroll", into: collected) {
            try await Self.against { try await Self.scroll(vertical: 0, horizontal: 0, on: $0) }
        }
        let record = try Self.only(collected)
        #expect(record["event"] as? String == "scroll")
        #expect((record["attributes"] as? [String: Any])?["entry"] as? String == "cli")
        #expect(record["outcome"] as? String == "ok")
        #expect(record["error"] == nil)
        #expect(record["counts"] as? [String: Int] == [
            "keyboard_reports": 0, "mouse_reports": 0, "scroll_notches_vertical": 0, "scroll_notches_horizontal": 0,
            "key_rollovers": 0, "key_hesitations": 0,
        ])
    }

    @Test func aScrollRecordsItsNotchesOnEachAxisAndTheRestBetweenThem() async throws {
        let collected = Collected()
        _ = try await Self.mcp("scroll", into: collected) {
            try await Self.against { try await Self.scroll(vertical: -3, horizontal: 2, on: $0) }
        }
        let record = try Self.only(collected)
        let counts = try #require(record["counts"] as? [String: Int])
        #expect(counts["scroll_notches_vertical"] == 3)
        #expect(counts["scroll_notches_horizontal"] == 2)
        #expect(counts["mouse_reports"] == 3)
        let attributes = try #require(record["attributes"] as? [String: Any])
        // The rest on the point, then a pause after each notch, totalled by kind.
        let pauses = try #require(attributes["pauses"] as? [String: [String: Any]])
        #expect(Set(pauses.keys) == ["rest", "notch"])
        #expect(pauses["rest"]?["count"] as? Int == 1)
        #expect(pauses["notch"]?["count"] as? Int == 3)
        #expect((pauses["notch"]?["ms"] as? Double).map { (600 ... 900).contains($0) } == true)
        #expect(attributes["double_click_ms"] is Double)
        #expect(attributes["key_repeat_delay_ms"] is Double)
        #expect(attributes["seed"] is String)
        // The pointer was already on its point, so the move there drew a path of no length.
        let paths = try #require(attributes["paths"] as? [[String: Any]])
        try #require(paths.count == 1)
        #expect(paths[0].filter { !["bow", "halfway"].contains($0.key) }.compactMapValues { $0 as? Double } == ["fitts_width": 20, "planned_ms": 0, "ends_kept": 1, "bow_kept": 1, "steered_reports": 0, "closing_reports": 0, "lost_reports": 0])
        // The bow and speed profile it drew: the pointer's randomness is seed 1, and the move is its first draw.
        var generator = SeededGenerator(seed: 1)
        let drawn = try Trajectory(from: Self.at, toward: .point(Self.at), drawing: &generator)
        #expect(paths[0]["bow"] as? Double == drawn.bow)
        #expect(paths[0]["halfway"] as? Double == drawn.halfway)
        // A point is aimed at exactly, from where the cursor was, and read back there when it landed.
        #expect(paths[0]["from"] as? [Double] == [40, 30])
        #expect(paths[0]["aimed"] as? [Double] == [40, 30])
        #expect(paths[0]["landed"] as? [Double] == [40, 30])
        #expect(paths[0]["box"] == nil)
        // Which of the four structures the move drew, by its design-note name.
        #expect(Set(["direct", "undershoot", "overshoot", "two_corrections"]).contains(paths[0]["structure"] as? String ?? ""))
        // The layout the path was kept on, as the pointer read it.
        #expect(paths[0]["displays"] as? [[Double]] == [[-1e6, -1e6, 2e6, 2e6]])
    }

    /// Typing records its waits beside the pointer's, totalled by the report each ends in,
    /// and a report for every change of the keys held.
    @Test func typingRecordsItsWaitsByTheReportEachEndsIn() async throws {
        let collected = Collected()
        _ = try await Self.mcp("type", into: collected) {
            try await Self.against { devices in
                try await TypeCommand.type("Ab", on: VerbTests.us, into: .anywhere,
                                           with: Typist(keyboard: devices.keyboard, clock: ManualClock(), randomness: RandomSource(seed: 1), traced: devices.trail.typed),
                                           front: { nil })
            }
        }
        let record = try Self.only(collected)
        #expect((record["counts"] as? [String: Int])?["keyboard_reports"] == 6)
        let pauses = try #require((record["attributes"] as? [String: Any])?["pauses"] as? [String: [String: Any]])
        #expect(pauses.mapValues { $0["count"] as? Int } == ["modifier_down": 1, "key_down": 2, "key_up": 2, "modifier_up": 1])
        #expect((pauses["key_up"]?["ms"] as? Double).map { (80 ... 400).contains($0) } == true)
        // Every report went out on time on a fake clock, and the record says so.
        #expect((record["attributes"] as? [String: Any])?["keys_late_ms"] as? Double == 0)
        #expect((record["counts"] as? [String: Int])?["key_rollovers"] == 0)
        #expect((record["attributes"] as? [String: Any])?["key_hesitation_ms"] as? Double == 0)
    }

    /// Prose rolls over and hesitates, and its record says how often: the rollovers counted,
    /// the hesitations counted and their drawn lengths totalled, and every character's
    /// key-down ending a `key_down` wait, hesitation or none.
    @Test func typingRecordsItsRolloversAndHesitations() async throws {
        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 4)
        let collected = Collected()
        _ = try await Self.mcp("type", into: collected) {
            try await Self.against { devices in
                try await TypeCommand.type(text, on: VerbTests.us, into: .anywhere,
                                           with: Typist(keyboard: devices.keyboard, clock: ManualClock(), randomness: RandomSource(seed: 1), traced: devices.trail.typed),
                                           front: { nil })
            }
        }
        let record = try Self.only(collected)
        #expect(((record["counts"] as? [String: Int])?["key_rollovers"] ?? 0) > 0)
        #expect(((record["counts"] as? [String: Int])?["key_hesitations"] ?? 0) > 0)
        let attributes = try #require(record["attributes"] as? [String: Any])
        // Each hesitation is 150 ms or more.
        #expect((attributes["key_hesitation_ms"] as? Double).map { $0 >= 150 } == true)
        let pauses = try #require(attributes["pauses"] as? [String: [String: Any]])
        #expect(pauses["key_down"]?["count"] as? Int == text.count)
    }

    /// A move the cursor never follows throws, and its record still carries the move: the box
    /// it was given and the point drawn inside it, every steered report given up on, and the
    /// closing loop's reports up to the stall that stopped it, and no landing. The error
    /// names the box too. Through the pointer `Devices` opens, which is where moves are recorded.
    @Test func aMoveThatWouldNotReachIsRecordedWithItsPath() async throws {
        let collected = Collected()
        let thrown = await #expect(throws: (any Error).self) {
            try await Self.mcp("move", into: collected) {
                // The far end's cursor is always at (0, 0).
                try await Self.against { try await MoveCommand.move(to: try await $0.placed(.box(ScreenRect.at(30, -5, 20, 10))), with: $0.pointer) }
            }
        }
        // Half the box is above the display, so the move is drawn inside the half it shows.
        #expect(thrown.map { "\($0)".contains("drawn inside the box 30,0,20,5, the part of 30,-5,20,10 on a display") } == true,
                "\(String(describing: thrown))")
        let record = try Self.only(collected)
        #expect(record["outcome"] as? String == "failed")
        let recorded = try #require((record["attributes"] as? [String: Any])?["paths"] as? [[String: Any]])
        try #require(recorded.count == 1)
        // The layout as the daemon answered it, which the path was kept on.
        #expect(recorded[0]["displays"] as? [[Double]] == [[0, 0, 1920, 1080]])
        let paths = recorded.map { $0.compactMapValues { $0 as? Double } }
        #expect(paths[0]["planned_ms"].map { $0 > 0 } == true)
        #expect(paths[0]["ends_kept"].map { (0 ... 1).contains($0) } == true)
        #expect(paths[0]["bow_kept"].map { (0 ... 1).contains($0) } == true)
        #expect(paths[0]["steered_reports"].map { $0 > 0 } == true)
        #expect(paths[0]["lost_reports"] == paths[0]["steered_reports"])
        #expect(paths[0]["closing_reports"] == Double(Pointer.stalls))
        #expect(paths[0]["fitts_width"] == 5)
        #expect(recorded[0]["box"] as? [Double] == [30, 0, 20, 5])
        #expect(recorded[0]["bound"] as? [Double] == [30, -5, 20, 10])
        #expect(recorded[0]["from"] as? [Double] == [0, 0])
        #expect(Set(["direct", "undershoot", "overshoot", "two_corrections"]).contains(recorded[0]["structure"] as? String ?? ""))
        let aimed = try #require(recorded[0]["aimed"] as? [Double])
        #expect((32 ... 48).contains(aimed[0]) && (0 ... 5).contains(aimed[1]), "\(aimed)")
        #expect(recorded[0]["landed"] == nil)
    }

    /// The cancel lands inside the pause after the second notch, from the task the roll runs
    /// in, so the roll stops before its third notch and the record says how far it got,
    /// the pause it stopped in included.
    @Test func aScrollCancelledPartWayIsRecordedAsCancelledWithTheNotchesItSent() async throws {
        let collected = Collected(), clock = ManualClock()
        clock.cancel(afterSleeps: 3) { withUnsafeCurrentTask { $0?.cancel() } }
        let roll = Task {
            try await Self.mcp("scroll", into: collected) {
                try await Self.against { try await Self.scroll(vertical: 10, horizontal: 0, clock: clock, on: $0) }
            }
        }
        let stopped = await #expect(throws: (any Error).self) { try await roll.value }
        #expect(stopped?.causes.contains { $0 is CancellationError } == true)
        let record = try Self.only(collected)
        #expect(record["outcome"] as? String == "cancelled")
        #expect(record["error"] as? String == "the run was cancelled")
        #expect((record["counts"] as? [String: Int])?["scroll_notches_vertical"] == 2)
        let pauses = try #require((record["attributes"] as? [String: Any])?["pauses"] as? [String: [String: Any]])
        #expect(pauses["rest"]?["count"] as? Int == 1)
        #expect(pauses["notch"]?["count"] as? Int == 2)
    }

    /// The error on the record is the sentence the caller was given.
    @Test func aFailedVerbIsRecordedWithWhatItsCallerWasTold() async throws {
        let collected = Collected()
        let thrown = await #expect(throws: (any Error).self) {
            try await Self.mcp("scroll", into: collected) {
                try await Self.against(acknowledging: 1) { try await Self.scroll(vertical: 5, horizontal: 0, on: $0) }
            }
        }
        let record = try Self.only(collected)
        #expect(record["outcome"] as? String == "failed")
        #expect(record["error"] as? String == thrown?.reported)
        #expect((record["counts"] as? [String: Int])?["scroll_notches_vertical"] == 1)
    }

    /// A tool call is one invocation, named after its tool. The tool is a stub, so this
    /// checks the dispatcher and nothing a verb does.
    @Test func anMcpToolCallIsRecordedUnderItsToolsName() async throws {
        let collected = Collected()
        let click = VerbTool(Help.click, []) { _, _ in "clicked" }
        try await Self.serve([click], into: collected)
        let record = try Self.only(collected)
        #expect(record["event"] as? String == "click")
        #expect((record["attributes"] as? [String: Any])?["entry"] as? String == "mcp")
        #expect(record["outcome"] as? String == "ok")
        #expect((record["counts"] as? [String: Int])?["queued_ms"] != nil)
    }

    /// One call to `click` against `tools`, served the way `vhid mcp` serves it: the
    /// session ends when stdin does, once every call it received is answered.
    private static func serve(_ tools: [VerbTool], into collected: Collected) async throws {
        try await Telemetry.$export.withValue(collected.export) {
            let stdio = Stdio(), transport = AnsweringTransport(stdio)
            stdio.call(1, then: [.end])
            try await McpCommand.serve(tools, on: .nobody, over: transport)
        }
    }

    /// A call naming no tool is refused as a protocol error, and recorded like any call -
    /// under the method, since a made-up name is not a verb.
    @Test func anMcpCallNamingNoToolIsRecordedAsFailed() async throws {
        let collected = Collected()
        try await Self.serve([], into: collected)
        let record = try Self.only(collected)
        #expect(record["event"] as? String == "tools/call")
        #expect(record["outcome"] as? String == "failed")
        #expect((record["error"] as? String)?.contains("there is no tool called") == true)
    }

    /// The answer goes out before the record does, and the record still lands once the
    /// outbox the process drains at exit is drained.
    @Test func anMcpCallIsAnsweredWithoutWaitingOnItsRecord() async throws {
        let answered = Gate(), sawAnswer = Mutex<Bool?>(nil)
        let outbox = Outbox(Edge(collector: .init(endpoint: .base("http://c:4318")),
                                 file: FileManager.default.temporaryDirectory.appending(path: "vhid-tests-\(UUID().uuidString)/events.jsonl"),
                                 deliver: { _ in
                                     try await answered.until(for: "the call to be answered")
                                     sawAnswer.withLock { $0 = true }
                                 }))
        let click = VerbTool(Help.click, []) { _, _ in "clicked" }
        let stdio = Stdio(), transport = AnsweringTransport(stdio)
        stdio.call(1, then: [])
        let session = Task {
            try await Telemetry.$export.withValue({ outbox.add($0) }) {
                try await McpCommand.serve([click], on: .nobody, over: transport)
            }
        }
        _ = await stdio.firstSent()
        answered.open()
        stdio.feed([.end])
        try await session.value
        await outbox.drained()
        #expect(sawAnswer.withLock { $0 } == true)
    }

    /// Says what `UntypeableCharacters` says, with a character of a password in it.
    private struct QuotesTheText: Error, CustomStringConvertible {
        var description: String { "U.S. has no keys for €" }
    }

    /// `type`'s errors can quote the text it was given, so its record names their kinds.
    @Test func aVerbThatTypesTextIsRecordedWithItsErrorsKindsNotTheirWords() async throws {
        let collected = Collected()
        _ = try? await Self.mcp("type", into: collected) {
            Telemetry.withholdErrorWords()
            throw QuotesTheText()
        }
        #expect("\(try collected.written)".contains("€") == false)
        #expect(try Self.only(collected)["error"] as? String == "QuotesTheText")
    }

    @Test func refusedToolArgumentsAreRecordedWithoutBeingQuoted() async throws {
        let collected = Collected()
        _ = try? await Self.mcp("type", into: collected) { throw ArgumentRefused("text 123456 is not a string") }
        #expect(try Self.only(collected)["error"] as? String == Telemetry.refusedArguments)
    }

    /// A cancel that lands while a verb fails for its own reason does not hide the reason.
    @Test func aVerbThatFailedAsACancelLandedIsRecordedAsFailed() async throws {
        let collected = Collected()
        let run = Task {
            try await Self.mcp("click", into: collected) {
                withUnsafeCurrentTask { $0?.cancel() }
                throw UnreachableTests.devicesDown
            }
        }
        _ = await run.result
        #expect(try Self.only(collected)["outcome"] as? String == "failed")
    }

    /// The command line and MCP name a verb the same way, so one verb's records are found
    /// under one name.
    @Test func aCommandIsNamedAsItIsTypedAndAsItsToolIs() {
        #expect(Entry.name(of: Vhid.self, under: Vhid.self) == "vhid")
        #expect(Entry.name(of: DriverCommand.State.self, under: Vhid.self) == "driver state")
        let commands = Vhid.configuration.subcommands.map { Entry.name(of: $0, under: Vhid.self) }
        for tool in Tools.all.map(\.tool.name) {
            #expect(commands.contains(tool), "no command is named \(tool)")
        }
    }

    // MARK: the command line's dispatcher

    /// `arguments` run as `Vhid.main` runs argv. Whatever the run threw is the record's to say.
    private static func commandLine(_ arguments: [String], into collected: Collected) async {
        _ = try? await cli(Vhid._commandName, into: collected) { try await Entry.commandLine(Vhid.self, arguments) }
    }

    /// A verdict is the verb's answer, not a failure: `doctor` on a Mac that is not ready
    /// ran, and its record says so, while the status it judged is what the process exits with.
    @Test func aVerdictIsRecordedAsARunThatEndedWell() async throws {
        let collected = Collected()
        let ran = try await Self.cli(Vhid._commandName, into: collected) {
            try await Entry.commandLine(Vhid.self, ["doctor", "--service", Installation.nobody.service])
        }
        guard case .judged(1) = ran else { Issue.record("\(ran)"); return }
        let record = try #require(try collected.written.first { $0["event"] as? String == "doctor" })
        #expect(record["outcome"] as? String == "ok")
        #expect(record["error"] == nil)
    }

    /// ArgumentParser answers `--help` with a `help` command it never declares among
    /// `vhid`'s subcommands.
    @Test func askingForHelpIsRecordedAsHelp() async throws {
        for arguments in [["--help"], ["scroll", "--help"], ["help", "click"]] {
            let collected = Collected()
            await Self.commandLine(arguments, into: collected)
            let record = try Self.only(collected)
            #expect(record["event"] as? String == "help", "\(arguments)")
            #expect(record["outcome"] as? String == "ok", "\(arguments)")
        }
    }

    /// The refusal quotes the argument back to the operator, and the record does not:
    /// this one was meant for a password field.
    @Test func refusedArgumentsAreRecordedUnderTheRootWithoutBeingQuoted() async throws {
        let collected = Collected()
        await Self.commandLine(["type", "a", "hunter2"], into: collected)
        #expect("\(try collected.written)".contains("hunter2") == false)
        let refused = try Self.only(collected)
        #expect(refused["error"] as? String == Telemetry.refusedArguments)
    }

    /// Refused arguments go unquoted through either door however they were refused - by a
    /// tool, or by ArgumentParser's validation - and every other error is said as that
    /// door's caller is told it.
    @Test func eitherDoorSaysRefusedArgumentsUnquotedAndTheRestAsItsCallerIsTold() {
        let cli = Entry.cli(under: Vhid.self), mcp = Entry.mcp(under: Vhid.self)
        for entry in [cli, mcp] {
            for refusal: any Error in [ArgumentRefused("hunter2"), ValidationError("hunter2")] {
                #expect(entry.said(refusal) == Telemetry.refusedArguments, "\(entry.door) \(refusal)")
            }
            #expect(entry.said(CancellationError()) == CancellationError().reported)
        }
        struct Broke: Error, CustomStringConvertible { var description: String { "the reading broke" } }
        let failed = Broke()
        #expect(mcp.said(failed) == failed.reported)
        #expect(cli.said(failed) == Vhid.message(for: failed))
        #expect(cli.said(CleanExit.helpRequest()).isEmpty)
    }

    @Test func anArgumentThatCannotBeParsedIsRecordedUnderTheRoot() async throws {
        let collected = Collected()
        await Self.commandLine(["clik"], into: collected)
        let record = try Self.only(collected)
        #expect(record["event"] as? String == "vhid")
        #expect(record["outcome"] as? String == "failed")
        #expect((record["error"] as? String)?.isEmpty == false)
    }

    /// A session stopped from outside - Control-C or SIGTERM, which cancel the task serving
    /// it - withdraws the call it is running, whose record says it was cancelled and what
    /// it had sent, and ends once that record is out.
    @Test func aSessionStoppedFromOutsideRecordsItsRunningCallAsCancelled() async throws {
        let (began, begin) = AsyncStream<Void>.makeStream()
        let waiting = VerbTool(Help.click, []) { _, _ in
            Telemetry.tally(.mouseReports)
            begin.yield()
            try await Task.sleep(for: .seconds(3600))
            return "clicked"
        }
        let collected = Collected(), stdio = Stdio(), signals = FirstSignal()
        let session = Task {
            try await Telemetry.$export.withValue(collected.export) {
                try await McpCommand.serve([waiting], on: Installation(service: "ai.promptctl.vhid.tests.nobody")!,
                                           over: AnsweringTransport(stdio), stoppedBy: signals)
            }
        }
        stdio.call(4, then: [])
        for await _ in began { break }
        // As the command line's watch does: the signal is taken, then the session cancelled.
        _ = signals.take(SIGTERM)
        session.cancel()
        let ended = await withTaskGroup(of: Result<Void, any Error>?.self) { race in
            race.addTask { await session.result }
            race.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            defer { race.cancelAll() }
            return await race.next() ?? nil
        }
        let ending = try #require(ended, "the session is still serving after its task was cancelled")
        #expect(throws: CancellationError.self) { try ending.get() }
        let record = try Self.only(collected)
        #expect(record["event"] as? String == "click")
        #expect(record["outcome"] as? String == "cancelled")
        #expect((record["counts"] as? [String: Int])?["mouse_reports"] == 1)
        #expect((record["attributes"] as? [String: Any])?["signal"] as? String == "SIGTERM")
    }

    /// A stopped session ends only once the call it withdrew has finished stopping: a
    /// withdrawn verb hands the devices back and lets go of what it holds on its way out,
    /// and its record says what it sent by then.
    @Test(.timeLimit(.minutes(1))) func aStoppedSessionWaitsForItsWithdrawnCallToFinishStopping() async throws {
        let (began, begin) = AsyncStream<Void>.makeStream()
        let (handedBack, handBack) = AsyncStream<Void>.makeStream()
        let holding = VerbTool(Help.click, []) { _, _ in
            begin.yield()
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                // Waited on outside the cancelled task, which would end the wait at once.
                await Task { for await _ in handedBack { break } }.value
                Telemetry.tally(.mouseReports)
                throw error
            }
            return "clicked"
        }
        let collected = Collected(), stdio = Stdio(), transport = AnsweringTransport(stdio), served = Mutex(false)
        let session = Task {
            defer { served.withLock { $0 = true } }
            try await Telemetry.$export.withValue(collected.export) {
                try await McpCommand.serve([holding], on: .nobody, over: transport)
            }
        }
        stdio.call(4, then: [])
        for await _ in began { break }
        session.cancel()
        await transport.until { $0.isWaitingOnCalls }
        #expect(!served.withLock { $0 }, "the session ended under a call still stopping")
        handBack.yield()
        await #expect(throws: CancellationError.self) { try await session.value }
        let record = try Self.only(collected)
        #expect(record["outcome"] as? String == "cancelled")
        #expect((record["counts"] as? [String: Int])?["mouse_reports"] == 1)
    }

    /// The command line's dispatcher, as a shell meets it: `vhid mcp` serving, then a
    /// signal. Its record is written as cancelled, it says so, and it then dies by that
    /// signal, which is what tells a shell it was stopped.
    @Test(arguments: [SIGINT, SIGTERM])
    func aVerbStoppedByASignalIsRecordedAsCancelledAndDiesByIt(_ number: Int32) async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "vhid-tests-\(UUID().uuidString)")
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = Bundle(for: Kept.self).bundleURL.deletingLastPathComponent().appending(path: "vhid")
        process.arguments = ["mcp"]
        // The record goes to this home's Library/Logs/vhid, and to no collector.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("OTEL_") }
            .merging(["CFFIXED_USER_HOME": home.path]) { $1 }
        let stderr = Pipe()
        (process.standardInput, process.standardOutput, process.standardError) = (stdin, stdout, stderr)
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: home)
        }
        // A server that never answers is ended, which ends the read below at end of file.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            process.terminate()
        }
        defer { watchdog.cancel() }
        // Answered, so the dispatcher is past setting up its watch.
        stdin.fileHandleForWriting.write(Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}"# + "\n").utf8))
        var answered = ""
        while !answered.contains("\n") {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            answered += String(decoding: chunk, as: UTF8.self)
        }
        try #require(answered.contains(#""id":1"#), "vhid mcp never answered initialize: \(answered)")
        watchdog.cancel()
        kill(process.processIdentifier, number)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == number)
        let said = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(said.hasSuffix("vhid: the run was cancelled\n"), "\(said)")
        let written = try String(contentsOf: home.appending(path: "Library/Logs/vhid/events.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        try #require(written.count == 1, "\(written)")
        #expect(written[0]?["event"] as? String == "mcp")
        #expect(written[0]?["outcome"] as? String == "cancelled")
        #expect(written[0]?["error"] as? String == "the run was cancelled")
        #expect((written[0]?["attributes"] as? [String: Any])?["signal"] as? String == (number == SIGINT ? "SIGINT" : "SIGTERM"))
    }

    /// A verb that reads the machine - `doctor`, `driver`, `service standing` - is stopped
    /// as every verb is: the cancel a signal makes ends the command its reading is
    /// running, the child with it, at once rather than at the command's limit, and the
    /// record says cancelled, names the command it ended, and how long it ran.
    ///
    /// The child says it runs through a FIFO and then sleeps for an hour, so the cancel
    /// lands while it runs and a verb that returns cancelled was ended by it: a command
    /// that ran to its limit would say it overran. A command reaps its child before it
    /// returns, so the child is gone by then. [LAW:no-ambient-temporal-coupling]
    @Test(.ownThread, .timeLimit(.minutes(1))) func aReadingCancelledMidCommandIsRecordedAsCancelledAndLeavesNoChild() async throws {
        let started = try FIFO()
        let collected = Collected()
        let begun = ContinuousClock.now
        let verb = Task {
            try await Self.cli("driver state", into: collected) {
                try await reading { stop in
                    Result { try Command("/bin/sh", "-c", "echo $$ > \(started.path); exec sleep 3600").run(by: .within(Command.limit, or: stop)) }
                }
            }
        }
        let child = try #require(pid_t(await started.line()))
        verb.cancel()
        await #expect(throws: CancellationError.self) { try await verb.value }
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        let took = ContinuousClock.now - begun
        let record = try Self.only(collected)
        #expect(record["event"] as? String == "driver state")
        #expect(record["outcome"] as? String == "cancelled")
        #expect(try #require(record["duration_ms"] as? Double) <= took / .milliseconds(1))
        let stopped = try #require((record["attributes"] as? [String: Any])?["stopped"] as? [String])
        #expect(stopped == ["sh -c echo $$ > \(started.path); exec sleep 3600"])
    }

    /// `doctor` prints its own report and exits 1 with nothing more to say.
    @Test func aVerbThatExitsNonzeroSayingNothingMoreIsRecordedWithNoError() async throws {
        let collected = Collected()
        _ = try? await Self.cli("doctor", into: collected) { throw ExitCode.failure }
        let record = try Self.only(collected)
        #expect(record["outcome"] as? String == "failed")
        #expect(record["error"] == nil)
    }
}
