import ArgumentParser
import Darwin
import Eyes
import Foundation
import Grants
import MCP
import Pixels
import System
import Version

/// eyes' verbs as MCP tools, over stdio, for an agent that sees the screen in one session
/// and acts on it through `vhid mcp` in another.
///
/// A copy of the shape of `vhid mcp` and not a shared target: the two packages link
/// nothing of each other's, and a target both depended on would be the one line that
/// joined them. [LAW:one-way-deps]
struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the verbs as MCP tools over stdin and stdout.",
        discussion: """
            Newline-delimited JSON-RPC on stdin and stdout, and nothing else on stdout: every \
            diagnostic goes to stderr. The tools are \(EyesTools.all().map(\.tool.name).joined(separator: ", ")). \
            They take what the verbs of the same name take, except that grants never asks, and \
            answer with what those verbs print, scope line first.
            """)

    /// The server as a client's initialize finds it, with its tools attached, each call
    /// held `underway` on the transport it will be started on.
    static func server(_ tools: [EyesTool] = EyesTools.all(), on transport: AnsweringTransport) async -> Server {
        let server = Server(name: "eyes", version: Version.current, capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools.map(\.tool)) }
        await server.withMethodHandler(CallTool.self) { request in
            guard let verb = tools.first(where: { $0.tool.name == request.name }) else {
                throw MCPError.invalidParams("there is no tool called \(request.name.debugDescription)")
            }
            // A verb that could not do what it was asked is a tool error, whose words the
            // model reads; a protocol error is for a request that named no tool at all.
            // [LAW:no-silent-failure]
            return try await transport.underway {
                do {
                    let said = try await verb.call(request.arguments ?? [:])
                    return .init(content: [.text(text: said, annotations: nil, _meta: nil)], isError: false)
                } catch where Task.isCancelled {
                    // A withdrawn call is answered with nothing, as the MCP spec says; what it
                    // said on the way out still reaches stderr. [LAW:no-silent-failure]
                    FileHandle.standardError.write(Data("eyes: \(request.name) withdrawn: \(error)\n".utf8))
                    throw CancellationError()
                } catch {
                    return .init(content: [.text(text: "\(error)", annotations: nil, _meta: nil)], isError: true)
                }
            }
        }
        return server
    }

    func run() async throws {
        // [LAW:single-enforcer] Stdout belongs to the protocol, made true of the descriptor
        // rather than asked of every line that might print: the transport writes to a copy
        // of the real stdout, and descriptor 1 becomes stderr.
        let protocolOut = FileDescriptor(rawValue: dup(STDOUT_FILENO))
        guard protocolOut.rawValue >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw Errno(rawValue: errno)
        }
        let transport = AnsweringTransport(StdioTransport(output: protocolOut))
        let server = await Self.server(on: transport)
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}

/// One verb as an MCP tool: what a client is shown, and what a call does.
struct EyesTool: Sendable {
    let tool: Tool
    let call: @Sendable ([String: Value]) async throws -> String
}

/// A tool call's arguments that the tool will not act on. Its words are the tool error.
struct ArgumentRefused: Error, CustomStringConvertible {
    let description: String
}

/// Every tool, in the order a client lists them. Each calls its verb's own core, so a tool
/// and its verb cannot come to say different things. [LAW:one-source-of-truth]
///
/// The screen is a parameter, so a test hands the tools a listing it wrote and the
/// process hands them the window server. [LAW:effects-at-boundaries]
enum EyesTools {
    typealias Listing = @Sendable () async throws -> WindowListing

    typealias DisplayList = @Sendable () async -> [Display]

    typealias FrontmostApp = @Sendable () async -> Frontmost?
    /// A reader's answer to one query: the chosen reader in the process, a fake in a test.
    typealias Look = @Sendable (SourceKind, Query) async throws -> Reading
    /// A fresh reading of the grants and the app they are charged to.
    typealias GrantsLook = @Sendable () async throws -> (GrantReading, Holder)

    static func all(
        windows listing: @escaping Listing = { try await Geometry.onScreen() },
        frontmost: @escaping FrontmostApp = { await Frontmost.now() },
        displays: @escaping DisplayList = { Geometry.displays() },
        reading look: @escaping Look = { source, query in try await source.reader.read(query) },
        grants: @escaping GrantsLook = { (try await GrantsVerb.reading(), try Holder.current()) }
    ) -> [EyesTool] {
        let serial = OneAtATime(look)
        let read: Look = { try await serial.read($0, $1) }
        return [windows(listing, frontmost: frontmost), Self.displays(displays), find(read), Self.read(read), Self.grants(grants)]
    }

    /// Where `find` and `read` look, as `--display`, `--window` and `--rect` take it.
    private static let place: [String: Value] = [
        "display": .object(["type": "integer", "description": .string(Help.display)]),
        "window": .object(["type": "integer", "description": .string(Help.window)]),
        "rect": .object(["type": "string", "description": .string(Help.rect)]),
        "limit": .object(["type": "integer", "minimum": 1, "description": "The most rows to answer with. Defaults to \(Limit.default.count)."]),
        "source": .object(["type": "string", "enum": .array(SourceKind.allCases.map { .string($0.rawValue) }), "description": .string(Help.source)]),
    ]

    /// Reading needs a grant - Accessibility for the tree, Screen Recording for pixels -
    /// which macOS asks of the process responsible for this one: for an MCP server, the
    /// app hosting it.
    private static let grant = " " + Help.needs.dropLast()
        + ", granted to the app that runs this server; merged answers with either."

    /// Where a missing grant is held, for a server: the app hosting it, not eyes.
    static let grantNote = " Under eyes mcp the grant is the app's that runs this server, not eyes'."

    static func find(_ look: @escaping Look) -> EyesTool { EyesTool(
        tool: Tool(
            name: "find",
            description: Find.configuration.abstract + " " + (Find.configuration.discussion) + grant,
            inputSchema: .object([
                "type": "object",
                "properties": .object(place.merging([
                    "text": .object(["type": "string", "description": .string(Help.text)]),
                    "exact": .object(["type": "boolean", "description": .string(Help.exact)]),
                    "edits": .object(["type": "integer", "minimum": 0, "description": .string(Help.edits)]),
                    "until": .object(["type": "string", "enum": .array(Until.allCases.map { .string($0.rawValue) }),
                                      "description": .string(Help.until)]),
                    "timeout": .object(["type": "number", "exclusiveMinimum": 0, "maximum": .double(Wait.longest),
                                        "description": .string(Help.timeout)]),
                ]) { $1 }),
                "required": .array(["text"]),
                "additionalProperties": false,
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)),
        call: { given in
            try refuseStray(given, taken: ["text", "exact", "edits", "display", "window", "rect", "limit", "source", "until", "timeout"])
            guard let text = try argument("text", in: given, \.stringValue, "a string") else {
                throw ArgumentRefused(description: "text is required: the text to look for")
            }
            let match = try Find.match(text, exact: try argument("exact", in: given, \.boolValue, "a boolean") ?? false,
                                       edits: try argument("edits", in: given, \.intValue, "an integer"), as: .argument)
            let until = try argument("until", in: given, \.stringValue, "a string").map { named in
                guard let until = Until(rawValue: named) else {
                    throw ArgumentRefused(description: "until is \(named), and it takes one of \(Until.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                return until
            }
            let wait = try Find.wait(until, timeout: try argument("timeout", in: given, { Double($0) }, "a number"),
                                     as: .argument)
            return try await answer(try query(match, given), try source(given), look, wait: wait)
        }) }

    static func read(_ look: @escaping Look) -> EyesTool { EyesTool(
        tool: Tool(
            name: "read",
            description: Read.configuration.abstract + grant,
            inputSchema: .object([
                "type": "object",
                "properties": .object(place),
                "additionalProperties": false,
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)),
        call: { given in
            try refuseStray(given, taken: ["display", "window", "rect", "limit", "source"])
            return try await answer(try query(nil, given), try source(given), look)
        }) }

    /// The region and limit `find` and `read` share, through the verbs' own rules.
    private static func query(_ match: Match?, _ given: [String: Value]) throws -> Query {
        let id = { (name: String) throws -> UInt32? in
            try argument(name, in: given, \.intValue, "an integer").map { n in
                guard let id = UInt32(exactly: n) else {
                    throw ArgumentRefused(description: "\(name) is \(n), which is not a window-server id (0 to \(UInt32.max))")
                }
                return id
            }
        }
        let region = try Where.region(display: try id("display"), window: try id("window"),
                                      rect: try argument("rect", in: given, \.stringValue, "a string"), as: .argument)
        let limit = try Where.limit(try argument("limit", in: given, \.intValue, "an integer") ?? Limit.default.count, as: .argument)
        return Query(match: match, region: region, limit: limit)
    }

    /// Which reader, as `--source` takes it.
    private static func source(_ given: [String: Value]) throws -> SourceKind {
        guard let named = try argument("source", in: given, \.stringValue, "a string") else { return .merged }
        guard let kind = SourceKind(argument: named) else {
            throw ArgumentRefused(description: "source is \(named), and it takes one of \(SourceKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return kind
    }

    /// The verbs' report, with a grant refusal pointed at the process that holds the grant
    /// for a server: the app hosting it, not eyes. A merge neither of whose readers could
    /// look says so for each. [LAW:no-silent-failure]
    private static func answer(_ query: Query, _ source: SourceKind, _ look: Look, wait: Wait? = nil) async throws -> String {
        do {
            return try await Report.text(query, source: source, wait: wait, grantNote: grantNote, reading: look)
        } catch let both as BothBlind {
            throw ArgumentRefused(description: "Neither reader could look. \(served(both.first)) \(served(both.second))")
        } catch let error as ReaderError where error.missingGrant {
            throw ArgumentRefused(description: served(error))
        }
    }

    /// An error as a server says it: a missing grant names the app that must hold it.
    private static func served(_ error: any Error) -> String {
        "\(error)\((error as? ReaderError)?.missingGrant == true ? grantNote : "")"
    }

    /// Read only: asking raises a dialog, which is a person's to raise from `eyes grants --ask`.
    static func grants(_ look: @escaping GrantsLook) -> EyesTool { EyesTool(
        tool: Tool(
            name: "grants",
            description: GrantsVerb.configuration.abstract
                + " Read fresh on every call, so a grant switched on since the server started is seen. Never prompts.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)),
        call: { given in
            try refuseStray(given, taken: [])
            let (reading, holder) = try await look()
            return GrantsVerb.report(reading, holder: holder, asked: [])
        }) }

    static func displays(_ list: @escaping DisplayList) -> EyesTool { EyesTool(
        tool: Tool(
            name: "displays",
            description: Displays.configuration.abstract
                + " Bounds are the screen points vhid click takes. Needs no grant.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)),
        call: { given in
            try refuseStray(given, taken: [])
            return Displays.report(await list())
        }) }

    static func windows(_ listing: @escaping Listing, frontmost: @escaping FrontmostApp) -> EyesTool { EyesTool(
        tool: Tool(
            name: "windows",
            description: Windows.configuration.abstract
                + " Coordinates are the screen points vhid click takes. Needs no grant.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "owner": .object([
                        "type": "string",
                        "description": "Only windows owned by applications whose name contains this.",
                    ]),
                ]),
                "additionalProperties": false,
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)),
        call: { given in
            let owner = try string("owner", in: given, only: ["owner"])
            try Windows.refuseEmpty(owner, named: "owner")
            let front = await frontmost()
            return Windows.report(try await listing(), owner: owner, frontmost: front)
        }) }

    /// The one optional string argument `name`, refusing any argument not in `taken` and
    /// a value of any other type, rather than ignoring either. [LAW:parse-dont-validate]
    static func string(_ name: String, in given: [String: Value], only taken: [String]) throws -> String? {
        try refuseStray(given, taken: taken)
        return try argument(name, in: given, \.stringValue, "a string")
    }

    /// The optional argument `name` as the type `read` takes out of it, refusing a value of
    /// any other type rather than ignoring it. [LAW:parse-dont-validate]
    static func argument<T>(_ name: String, in given: [String: Value], _ read: (Value) -> T?, _ type: String) throws -> T? {
        // An explicit null is how many clients leave an optional argument unset.
        guard let value = given[name], !value.isNull else { return nil }
        guard let taken = read(value) else { throw ArgumentRefused(description: "\(name) is \(value), and it takes \(type)") }
        return taken
    }

    /// Any argument not in `taken` is refused by name rather than ignored.
    static func refuseStray(_ given: [String: Value], taken: [String]) throws {
        guard let stray = given.keys.sorted().first(where: { !taken.contains($0) }) else { return }
        throw ArgumentRefused(description: "\(stray) is not an argument this tool takes: "
            + (taken.isEmpty ? "it takes none" : "it takes \(taken.joined(separator: ", "))"))
    }
}

/// Reads one query at a time. Two Vision recognitions in flight in one process crashed
/// inside TextRecognition in 4 of 15 runs (PixelReader), and the MCP server starts a task
/// per request, so an agent's parallel calls would otherwise put two in flight.
actor OneAtATime {
    private let look: EyesTools.Look
    private var tail: Task<Void, Never>?

    init(_ look: @escaping EyesTools.Look) { self.look = look }

    func read(_ source: SourceKind, _ query: Query) async throws -> Reading {
        // A call withdrawn before it got here never joins the queue. The check inside the
        // task below cannot see it: that task is not cancelled until the handler at the
        // bottom is installed, and with nothing ahead of it, it reads first. Measured: 1 run
        // in 8 of aWithdrawnCallLeavesTheQueueWithoutReading read the withdrawn call.
        try Task.checkCancellation()
        let before = tail
        let look = look
        let mine = Task {
            _ = await before?.value
            // A call withdrawn while it waited leaves without reading. [LAW:no-silent-failure]
            try Task.checkCancellation()
            return try await look(source, query)
        }
        tail = Task { _ = try? await mine.value }
        return try await withTaskCancellationHandler { try await mine.value } onCancel: { mine.cancel() }
    }
}
