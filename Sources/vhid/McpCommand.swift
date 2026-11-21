import ArgumentParser
import Darwin
import enum EyesVerbs.Entry
import Foundation
import Input
import Installations
import MCP
import Signals
import System
import Telemetry
import Turns
import Version

/// The verbs as MCP tools, over stdio, for an agent that drives a Mac in one session
/// rather than a process per keystroke.
struct McpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the verbs as MCP tools over stdin and stdout.",
        discussion: """
            Newline-delimited JSON-RPC on stdin and stdout, and nothing else on stdout: every \
            diagnostic goes to stderr. The tools are \(Tools.all.map(\.tool.name).joined(separator: ", ")). \
            They take what the verbs of the same name take and answer with what those verbs \
            print.

            Calls that reach the daemon run one at a time, even when a client sends them together, \
            but calls sent together run in no promised order: a call that must follow another, a \
            type after the click that focuses a field, is sent once the first one's answer is back. \
            Each such call connects to the daemon and disconnects when it returns. The daemon serves \
            one client at a time, so a session that held its connection open would refuse every other \
            caller for as long as it ran: a vhid click from a shell, and every other agent's session. \
            Between calls, this session holds nothing.

            look reads the screen in this process and asks nothing of the daemon, so it waits \
            behind no other call, and a click sent beside a look that is waiting for text is not delayed by it.
            """)

    @OptionGroup var service: ServiceOption

    /// How the tools work together, as the server says it at initialize: one screen point
    /// for every tool, and the look-act-look loop. A copy of docs/mcp-instructions.txt, which
    /// the plugin's skill opens with too, and a test holds each to the file.
    /// [LAW:one-source-of-truth]
    static let guidance = """
        vhid is one MCP server that sees the screen and drives a virtual keyboard and mouse that macOS takes for hardware. `look` reads the screen: the displays, the windows front to back, and the text in a place, with the point `click` takes for each run. `type`, `press`, `gesture`, `click`, `move`, `scroll` and `drag` act through the devices, and `play` runs a timed script of them.

        Every point a tool prints or takes is the same screen point. The point `look` prints beside a run is the point `click` takes, as printed: no scaling, no offset, negative on a display left of or above the main one. Beside each point `look` prints a box around the text that holds the point, as x,y,width,height in the same points: the form `look`'s `rect` takes, and `click`, `move` and `scroll` take it too, as `box`, and `drag` as `from` or `to`, pressing a point drawn inside it as a hand lands somewhere on a button rather than on its exact centre.

        No tool decides anything. `click` presses whatever is at the point it is given, `type` types into whatever has keyboard focus, and `look` reports what is on screen, not whether an act did what was meant. So work in a loop:

        1. Look: `look` with no arguments for what is in front, with `text` for where the text is.
        2. Act on what you saw.
        3. Look again at the same place. `look` with `text`, `until` and a `timeout` waits for the change; do not sleep and retry.

        Done means a look after the act showed the change. An act's answer says the act happened, not what it did.
        """

    /// What a client's initialize tells it: the guidance, then which server and version it
    /// is talking to. The model reads a server's instructions, not its `serverInfo`, so the
    /// version is said here too, from the one the binary was stamped with, and an agent
    /// can tell which of the guidance's arguments it can pass. [LAW:one-source-of-truth]
    static let instructions = guidance + "\n\nThis is vhid \(Version.current)."

    /// The server as a client's initialize finds it, with `tools` attached to run against
    /// `installation`, each call held `underway` on the transport it will be started on and
    /// recorded as one unit of work of its own trace - its record handed to the outbox before
    /// its answer goes, and sent without the answer waiting on a collector.
    static func server(_ tools: [VerbTool] = Tools.all, on installation: Installation, over transport: AnsweringTransport,
                       stoppedBy signals: FirstSignal? = nil) async -> Server {
        let server = Server(name: "vhid", version: Version.current, instructions: instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        // The SDK runs every request in a task of its own, so two calls sent together - a
        // click and a type in one turn of an agent's - would reach for the daemon at once,
        // and it serves one client: the second came back refused as busy, by this very
        // process. Taking turns makes the session one client again. A look asks nothing of
        // the daemon, and takes no turn.
        let turns = Turns()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools.map(\.tool)) }
        await server.withMethodHandler(CallTool.self) { request in
            let arrived = ContinuousClock.now
            // Recorded under the method, not the name: a name the client made up is not a
            // verb, and would make one event per made-up name. The error says which.
            guard let verb = tools.first(where: { $0.tool.name == request.name }) else {
                let refusal = MCPError.invalidParams("there is no tool called \(request.name.debugDescription)")
                return try await dispatched(CallTool.name, stoppedBy: signals) { throw refusal }
            }
            // A verb that could not do what it was asked is a tool error, whose words the
            // model reads; a protocol error is for a request that named no tool at all. A
            // call the client withdrew is answered like any other, and the transport drops
            // the answer, as the MCP spec says a cancelled request's is. What the verb said on
            // the way out still goes to stderr, because it can be the one report of what the
            // verb had already done when it was withdrawn. [LAW:no-silent-failure]
            return try await transport.underway {
                do {
                    let said = try await dispatched(request.name, stoppedBy: signals) {
                        try await verb.call(request.arguments ?? [:], on: installation, taking: turns, arrived: arrived)
                    }
                    return .init(content: [.text(text: said, annotations: nil, _meta: nil)], isError: false)
                } catch where error.isCancellation {
                    FileHandle.standardError.write(Data("vhid: \(request.name) withdrawn: \(error.reported)\n".utf8))
                    return .init(content: [.text(text: "withdrawn: \(error.reported)", annotations: nil, _meta: nil)], isError: true)
                } catch {
                    return .init(content: [.text(text: error.reported, annotations: nil, _meta: nil)], isError: true)
                }
            }
        }
        return server
    }

    /// Runs `work` as one call's unit of work, of a trace of its own: the tool it named,
    /// through this dispatcher, and the signal that stopped the session, if one did.
    static func dispatched<T>(_ name: String, stoppedBy signals: FirstSignal?, _ work: () async throws -> T) async throws -> T {
        try await Entry.mcp.unit(name, trace: .fresh, said: { $0.reported }) {
            defer { signals?.noted() }
            return try await work()
        }
    }

    func run() async throws {
        let installation = try service.installation()
        // [LAW:single-enforcer] Stdout belongs to the protocol, and that is made true of the
        // descriptor rather than asked of every line of code that might print. The
        // transport writes to a copy of the real stdout, and descriptor 1 becomes stderr, so
        // a stray `print` anywhere in the process lands among the diagnostics and not in
        // the middle of a JSON-RPC message.
        let protocolOut = FileDescriptor(rawValue: dup(STDOUT_FILENO))
        guard protocolOut.rawValue >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw Errno(rawValue: errno)
        }

        try await Self.serve(on: installation, over: AnsweringTransport(StdioTransport(output: protocolOut)), stoppedBy: Vhid.signals)
    }

    /// Serves `tools` over `transport` until the client hangs up or the serving task is
    /// cancelled, as Control-C and SIGTERM cancel it. A cancel withdraws every call owed,
    /// so each one stops as a client's cancel would stop it, and ends the session. Returns
    /// once every call the transport received has been answered, or, once cancelled, once
    /// every call running has stopped - each record in the outbox by then, which the
    /// process drains at exit - throwing if it was cancelled.
    /// Each call's record names the signal in `signals` that stopped the session, if one did.
    ///
    /// The cancel has to be carried in by hand: the SDK serves from a task of its own,
    /// which no cancel of this one reaches.
    static func serve(_ tools: [VerbTool] = Tools.all, on installation: Installation, over transport: AnsweringTransport,
                      stoppedBy signals: FirstSignal? = nil) async throws {
        let server = await server(tools, on: installation, over: transport, stoppedBy: signals)
        try await server.start(transport: transport)
        await withTaskCancellationHandler {
            await server.waitUntilCompleted()
        } onCancel: {
            Task {
                await transport.withdrawEverything()
                await server.stop()
            }
        }
        await transport.everyCallStopped()
        try Task.checkCancellation()
    }
}
