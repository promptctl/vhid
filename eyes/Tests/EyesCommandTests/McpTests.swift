import Foundation
import Eyes
import Grants
import MCP
import Pixels
@testable import Tree
import Version
import Telemetry
import TelemetryTesting
import Testing
@testable import EyesCommand

/// What `eyes mcp` offers, asked through a client over an in-memory transport, with a
/// listing written here in place of the window server.
/// Serialized: the fake reader records into one shared `asked`.
@Suite(.serialized, .eventsKept) struct McpTests {
    private static let listing = WindowListing(
        windows: [
            Window(id: 1, owner: "Safari", pid: 400, frame: ScreenRect(x: 0, y: 33, width: 1512, height: 949), layer: 0),
            Window(id: 2, owner: "Finder", pid: 401, frame: ScreenRect(x: -800, y: 0, width: 800, height: 600), layer: 0),
        ],
        excluded: [])
    private static let front = Frontmost(pid: 401, name: "Finder")
    private static let grantReading = GrantReading { $0 == .accessibility }
    private static let holder = Holder(executable: "/Applications/Claude.app/Contents/MacOS/Claude")

    /// Every query the fake reader was handed, so a test can check what reached it.
    actor Asked {
        var queries: [Query] = []
        var sources: [SourceKind] = []
        func add(_ q: Query, _ s: SourceKind) { queries.append(q); sources.append(s) }
    }
    private static let asked = Asked()

    /// A reader that sees one run, "Save", everywhere but display 666, where it has no grant.
    private static let look: EyesTools.Look = { source, query in .standing(try await seen(source, query)) }
    private static let seen: @Sendable (SourceKind, Query) async throws -> Reading = { source, query in
        await asked.add(query, source)
        if query.region == .display(666) { throw PixelsError.noGrant }
        if query.region == .display(667), source == .tree { throw TreeError.noGrant }
        if query.region == .display(669) {
            return Reading(outcome: .nearest([]), scope: Scope(region: ScreenRect(x: 0, y: 0, width: 10, height: 10), examined: 0,
                reach: .stopped(.merged(.blind(.tree, "\(TreeError.noGrant)", missingGrant: true), .read(.pixels, .whole)))))
        }
        if query.region == .display(670) {
            return Reading(outcome: .nearest([]), scope: Scope(region: ScreenRect(x: 0, y: 0, width: 10, height: 10), examined: 0,
                reach: .stopped(.merged(.read(.tree, .whole), .blind(.pixels, "\(PixelsError.noGrant)", missingGrant: true)))))
        }
        if query.region == .display(668) { throw BothBlind(first: TreeError.noGrant, second: PixelsError.noGrant) }
        let save = Found(text: Text("Save")!, frame: ScreenRect(x: -300, y: 40, width: 40, height: 20), source: .pixels(confidence: Confidence(1)!))
        return Reading(outcome: .matched(Matches([save])!), scope: Scope(region: ScreenRect(x: -1512, y: 316, width: 1512, height: 982), examined: 1, reach: .whole))
    }

    static let viewport = ScreenRect(x: 22, y: 190, width: 1200, height: 688)
    /// Window 219 shows one page, 220 two side by side, and 221's tree has no grant.
    private static let pages: Where.Place.Pages = { id in
        switch id {
        case 219: return Paged(pages: [viewport], examined: 40, stop: nil)
        case 220: return Paged(pages: [viewport, viewport], examined: 52, stop: nil)
        default: throw TreeError.noGrant
        }
    }

    /// A client connected to a server over `listing`, both torn down before this returns.
    private func connected<T>(_ body: (Client) async throws -> T) async throws -> T {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let transport = AnsweringTransport(serverSide)
        let server = await Mcp.server(EyesTools.all(windows: { Self.listing }, frontmost: { Self.front }, displays: { DisplaysCommandTests.desk }, reading: Self.look, grants: { (Self.grantReading, Self.holder) }, pages: Self.pages), on: transport)
        try await server.start(transport: transport)
        let client = Client(name: "test", version: "0")
        let result: Result<T, any Error>
        do {
            _ = try await client.connect(transport: clientSide)
            result = .success(try await body(client))
        } catch {
            result = .failure(error)
        }
        await client.disconnect()
        await server.stop()
        return try result.get()
    }

    private func call(_ arguments: [String: Value], tool: String = "windows") async throws -> (String, Bool?) {
        let (content, isError) = try await connected { try await $0.callTool(name: tool, arguments: arguments) }
        guard case .text(let said, _, _) = content.first else { return ("no text: \(content)", isError) }
        return (said, isError)
    }

    /// The binary and the server report the one stamped version, and the server the one
    /// wording of its pairing with vhid. [LAW:one-source-of-truth]
    @Test func theVersionIsTheStampedOneAndThePairingTheDocumentedOne() async throws {
        #expect(Eye.configuration.version == Version.current)
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let transport = AnsweringTransport(serverSide)
        let server = await Mcp.server(EyesTools.all(windows: { Self.listing }, frontmost: { Self.front }, displays: { DisplaysCommandTests.desk }, reading: Self.look, grants: { (Self.grantReading, Self.holder) }), on: transport)
        try await server.start(transport: transport)
        let result: Initialize.Result
        do {
            result = try await Client(name: "test", version: "0").connect(transport: clientSide)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
        #expect(result.serverInfo.name == "eyes")
        #expect(result.serverInfo.version == Version.current)
        // The pairing with vhid, as docs/mcp-instructions.txt words it for both servers.
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized
        let pairing = try String(contentsOf: root.appending(path: "docs/mcp-instructions.txt"), encoding: .utf8)
        #expect(result.instructions == pairing.trimmingCharacters(in: .newlines))
    }

    @Test func theToolsAreListedAndReadOnly() async throws {
        let tools = try await connected { try await $0.listTools().tools }
        #expect(tools.map(\.name) == ["windows", "displays", "find", "read", "grants"])
        #expect(tools.allSatisfy { $0.annotations.readOnlyHint == true })
    }

    /// The tool answers with exactly what the verb prints. [LAW:one-source-of-truth]
    @Test func windowsAnswersWithTheVerbsReport() async throws {
        for owner: Value in [.null, "finder"] {
            let (said, isError) = try await call(owner.isNull ? [:] : ["owner": owner])
            #expect(isError != true)
            #expect(said == Windows.report(Self.listing, owner: owner.stringValue, frontmost: Self.front))
        }
        #expect(try await call(["owner": .null]).0 == Windows.report(Self.listing, owner: nil, frontmost: Self.front))
    }

    /// The grants tool answers with the verb's report, never having asked.
    @Test func grantsAnswersWithTheVerbsReport() async throws {
        let (said, isError) = try await call([:], tool: "grants")
        #expect(isError != true)
        #expect(said == GrantsVerb.report(Self.grantReading, holder: Self.holder, asked: []))
        #expect(try await call(["ask": true], tool: "grants").1 == true)
    }

    /// Refusals come back as tool errors in the model's words, not as ignored arguments.
    @Test func argumentsItWillNotActOnAreToolErrors() async throws {
        for (arguments, expected): ([String: Value], String) in [
            (["owner": ""], "owner was given an empty value, which would filter out every window. Leave owner off to list them all."),
            (["owner": 3], "owner is 3, and it takes a string"),
            (["own": "Safari"], "own is not an argument this tool takes: it takes owner"),
        ] {
            let (said, isError) = try await call(arguments)
            #expect(isError == true)
            #expect(said == expected)
        }
    }

    @Test func displaysAnswersWithTheVerbsReportAndTakesNoArguments() async throws {
        let (said, isError) = try await call([:], tool: "displays")
        #expect(isError != true)
        #expect(said == Displays.report(DisplaysCommandTests.desk))
        let (refused, refusedIsError) = try await call(["display": 1], tool: "displays")
        #expect(refusedIsError == true)
        #expect(refused == "display is not an argument this tool takes: it takes none")
    }

    /// Each tool answers with what its verb prints for the same query: the arguments reach
    /// the reader through the verbs' own rules. [LAW:one-source-of-truth]
    @Test func findAndReadAnswerWithTheVerbsReport() async throws {
        for (tool, arguments, query): (String, [String: Value], Query) in [
            ("find", ["text": "save", "display": 1], Query(match: .contains("save"), region: .display(1))),
            ("find", ["text": "Save", "exact": true, "window": 9, "limit": 3], Query(match: .exact("Save"), region: .window(9), limit: Limit(3)!)),
            ("find", ["text": "Sabe", "edits": 1, "rect": "-400,0,200,100"],
             Query(match: .within(edits: Edits(1)!, of: "Sabe"), region: .rect(ScreenRect(x: -400, y: 0, width: 200, height: 100)))),
            ("read", ["display": 1, "limit": .null], Query(match: nil, region: .display(1))),
        ] {
            let (said, isError) = try await call(arguments, tool: tool)
            #expect(isError != true)
            #expect(await Self.asked.queries.last == query)
            #expect(await Self.asked.sources.last == .merged)
            #expect(said == (try await Report.text(query, source: .merged, reading: Self.look)))
        }
    }

    /// Each tool reads with the source it is given, and names it.
    @Test func findAndReadReadWithTheSourceGiven() async throws {
        for kind in SourceKind.allCases {
            for (tool, arguments): (String, [String: Value]) in [
                ("find", ["text": "save", "display": 1, "source": .string(kind.rawValue)]),
                ("read", ["display": 1, "source": .string(kind.rawValue)]),
            ] {
                let (said, isError) = try await call(arguments, tool: tool)
                #expect(isError != true)
                #expect(await Self.asked.sources.last == kind)
                #expect(said.contains(kind.looked))
            }
        }
    }

    /// Each reader's missing grant, and a merge with neither, is a tool error naming the grant.
    @Test func everyReadersMissingGrantIsAToolErrorNamingIt() async throws {
        let served = " Under eyes mcp the grant is the app's that runs this server, not eyes'."
        for (display, expected): (Int, String) in [

            (668, "Neither reader could look. \(TreeError.noGrant)\(served) \(PixelsError.noGrant)\(served)"),
        ] {
            let (said, isError) = try await call(["display": .int(display)], tool: "read")
            #expect(isError == true)
            #expect(said == expected)
        }
        let (said, isError) = try await call(["display": 667, "source": "tree"], tool: "read")
        #expect(isError == true)
        #expect(said == "\(TreeError.noGrant)\(served)")
    }

    /// A merge with one reader blind for want of a grant answers, and says where that grant is held.
    @Test func aMergeWithOneReaderBlindAnswersAndNamesWhereItsGrantIsHeld() async throws {
        let (said, isError) = try await call(["display": 669], tool: "read")
        #expect(isError != true)
        #expect(said.contains("by pixels alone"))
        #expect(said.contains("tree could not look (\(TreeError.noGrant) Under eyes mcp the grant is the app's that runs this server, not eyes'.)"))
    }

    /// A reader that could not look is a tool error that names the grant, never an empty answer.
    @Test func aMissingGrantIsAToolErrorNamingIt() async throws {
        for tool in ["find", "read"] {
            let (said, isError) = try await call(tool == "find" ? ["text": "Save", "display": 666] : ["display": 666], tool: tool)
            #expect(isError == true)
            #expect(said == "\(PixelsError.noGrant) Under eyes mcp the grant is the app's that runs this server, not eyes'.")
        }
    }

    @Test func findAndReadRefuseWhatTheVerbsRefuse() async throws {
        for (tool, arguments, expected): (String, [String: Value], String) in [
            ("find", [:], "text is required: the text to look for"),
            ("find", ["text": "  "], "the text to find is blank"),
            ("find", ["text": "a", "exact": true, "edits": 1], "give exact or edits, not both"),
            ("find", ["text": "a", "edits": -1], "edits cannot be negative"),
            ("find", ["text": "a", "exact": "yes"], "exact is yes, and it takes a boolean"),
            ("find", ["text": "a", "timeout": 5], "timeout needs until: it is how long to wait"),
            ("find", ["text": "a", "until": "gone"], "until is gone, and it takes one of present, absent"),
            ("find", ["text": "a", "until": "absent", "timeout": 0], "timeout is 0.0, and it takes seconds above 0 and at most 600"),
            ("read", ["limit": 0], "limit must be at least 1"),
            ("read", ["display": 1, "window": 2], "give at most one of display, window, page, rect"),
            ("read", ["display": -1], "display is -1, which is not a window-server id (0 to 4294967295)"),
            ("read", ["window": 4_294_967_296], "window is 4294967296, which is not a window-server id (0 to 4294967295)"),
            ("read", ["rect": "1,2,3"], "rect wants x,y,width,height in points - a positive size, nothing past 1000000 - got 1,2,3"),
            ("read", ["text": "a"], "text is not an argument this tool takes: it takes display, window, page, rect, limit, source"),
            ("read", ["source": "ocr"], "source is ocr, and it takes one of tree, pixels, merged"),
            ("read", ["page": 2, "rect": "1,2,3,4"], "give at most one of display, window, page, rect"),
            ("find", ["text": "a", "near": " "], "the text to find matches near is blank"),
        ] {
            let (said, isError) = try await call(arguments, tool: tool)
            #expect(isError == true, "\(tool) \(arguments)")
            #expect(said == expected)
        }
    }

    /// A wait answers with the verb's report of the read it ended on, led by how the wait
    /// went; running out of time is an answer, not a tool error.
    @Test func findWaitsAndSaysHowTheWaitWent() async throws {
        let (settled, settledError) = try await call(["text": "Save", "until": "present", "timeout": 1], tool: "find")
        #expect(settledError != true)
        #expect(settled.hasPrefix("present after 1 read in "))
        #expect(settled.contains(": 1 matched \"Save\" in "))
        let (timedOut, timedOutError) = try await call(["text": "Save", "until": "absent", "timeout": 0.3], tool: "find")
        #expect(timedOutError != true)
        #expect(timedOut.hasPrefix("timed out, not absent after "))
    }

    /// An absence a blind reader cannot prove is a tool error naming where its grant is held.
    @Test func anAbsenceWaitOnABlindReaderNamesWhereItsGrantIsHeld() async throws {
        let (said, isError) = try await call(["text": "Save", "display": 670, "until": "absent"], tool: "find")
        #expect(isError == true)
        #expect(said.hasPrefix("pixels could not look, so an absence cannot be proven"))
        #expect(said.hasSuffix(EyesTools.grantNote))
    }

    /// Reads never overlap, however many calls arrive at once: two Vision recognitions in
    /// one process are a measured crash.
    @Test func readsRunOneAtATime() async throws {
        actor Gauge {
            var now = 0, most = 0
            func enter() { now += 1; most = max(most, now) }
            func leave() { now -= 1 }
        }
        let gauge = Gauge()
        let serial = OneAtATime { _, query in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(20))
            await gauge.leave()
            return .standing(Reading(outcome: .nearest([]), scope: Scope(region: ScreenRect(x: 0, y: 0, width: 1, height: 1), examined: 0, reach: .whole)))
        }
        try await withThrowingTaskGroup(of: Judged.self) { group in
            for _ in 0..<5 { group.addTask { try await serial.read(.pixels, Query(match: nil, region: .display(1))) } }
            for try await _ in group {}
        }
        #expect(await gauge.most == 1)
    }

    /// Time spent queued is summed across a look's reads, so a wait whose early polls
    /// queued behind another call says so even when its last poll did not.
    @Test func queuedTimeIsSummedAcrossALooksReads() async throws {
        let blank = Reading(outcome: .nearest([]), scope: Scope(region: ScreenRect(x: 0, y: 0, width: 1, height: 1), examined: 0, reach: .whole))
        let (reading, started) = AsyncStream.makeStream(of: Void.self)
        let serial = OneAtATime { _, query in
            if query.match != nil { started.finish(); try await Task.sleep(for: .milliseconds(100)) }
            return .standing(blank)
        }
        let events = Collected()
        let blocker = Task { try await serial.read(.pixels, Query(match: .contains("slow"), region: .display(1))) }
        // The look queues only once the slow read is underway, not by a race to the queue.
        for await _ in reading {}
        try await Telemetry.$export.withValue(events.export) {
            try await Telemetry.unit("look") {
                _ = try await serial.read(.pixels, Query(match: nil, region: .display(1)))
                _ = try await serial.read(.pixels, Query(match: nil, region: .display(1)))
            }
        }
        _ = try await blocker.value
        #expect((events.all[0].counts["queued_ms"] ?? -1) >= 50)
    }

    /// A call withdrawn while it waits its turn never reads. The first read is held open
    /// by the test, not by a sleep, so a slow machine cannot finish it early.
    @Test func aWithdrawnCallLeavesTheQueueWithoutReading() async throws {
        actor Count { var n = 0; func add() -> Int { n += 1; return n } }
        let count = Count()
        let (started, starting) = AsyncStream.makeStream(of: Void.self)
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let serial = OneAtATime { _, _ in
            if await count.add() == 1 {
                starting.yield()
                for await _ in gate { break }
            }
            return .standing(Reading(outcome: .nearest([]), scope: Scope(region: ScreenRect(x: 0, y: 0, width: 1, height: 1), examined: 0, reach: .whole)))
        }
        let query = Query(match: nil, region: .display(1))
        let first = Task { try await serial.read(.pixels, query) }
        for await _ in started { break }
        let second = Task { try await serial.read(.pixels, query) }
        second.cancel()
        open.yield()
        _ = try await first.value
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await count.n == 1)
    }

    /// A page is found through the server's own search: its frame is the region read, and
    /// a window with two pages, or a tree with no grant, is refused as the verb refuses it.
    @Test func findReadsThePageTheSearchFound() async throws {
        let (_, isError) = try await call(["text": "Save", "page": 219], tool: "find")
        #expect(isError != true)
        #expect(await Self.asked.queries.last?.region == .page(window: 219, frame: Self.viewport))
        let (two, refused) = try await call(["text": "Save", "page": 220], tool: "find")
        #expect(refused == true && two.contains("2 web pages"))
        let (blind, _) = try await call(["page": 221], tool: "read")
        #expect(blind == "\(TreeError.noGrant)\(EyesTools.grantNote)")
    }
}
