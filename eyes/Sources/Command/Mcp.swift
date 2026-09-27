import ArgumentParser
import Darwin
import Eyes
import Foundation
import MCP
import System

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
            They take what the verbs of the same name take and answer with what those verbs \
            print, scope line first.
            """)

    /// The server as a client's initialize finds it, with its tools attached.
    static func server(_ tools: [EyesTool] = EyesTools.all()) async -> Server {
        let server = Server(name: "eyes", version: "0", capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools.map(\.tool)) }
        await server.withMethodHandler(CallTool.self) { request in
            guard let verb = tools.first(where: { $0.tool.name == request.name }) else {
                throw MCPError.invalidParams("there is no tool called \(request.name.debugDescription)")
            }
            // A verb that could not do what it was asked is a tool error, whose words the
            // model reads; a protocol error is for a request that named no tool at all.
            // [LAW:no-silent-failure]
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
        let server = await Self.server()
        try await server.start(transport: AnsweringTransport(StdioTransport(output: protocolOut)))
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

    static func all(windows listing: @escaping Listing = { try await Geometry.onScreen() }) -> [EyesTool] {
        [windows(listing)]
    }

    static func windows(_ listing: @escaping Listing) -> EyesTool { EyesTool(
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
            return Windows.report(try await listing(), owner: owner)
        }) }

    /// The one optional string argument `name`, refusing any argument not in `taken` and
    /// a value of any other type, rather than ignoring either. [LAW:parse-dont-validate]
    static func string(_ name: String, in given: [String: Value], only taken: [String]) throws -> String? {
        if let stray = given.keys.sorted().first(where: { !taken.contains($0) }) {
            throw ArgumentRefused(description: "\(stray) is not an argument this tool takes: it takes \(taken.joined(separator: ", "))")
        }
        // An explicit null is how many clients leave an optional argument unset.
        guard let value = given[name], !value.isNull else { return nil }
        guard let text = value.stringValue else {
            throw ArgumentRefused(description: "\(name) is \(value), and it takes a string")
        }
        return text
    }
}
