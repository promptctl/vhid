import ArgumentParser
import Darwin
import Foundation
import Input
import Installations
import MCP
import System
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

            Tool calls run one at a time, even when a client sends them together, but calls sent \
            together run in no promised order: a call that must follow another, a type after the \
            click that focuses a field, is sent once the first one's answer is back. Each call \
            connects to the daemon and disconnects when it returns. The daemon serves \
            one client at a time, so a session that held its connection open would refuse every other \
            caller for as long as it ran: a vhid click from a shell, and every other agent's session. \
            Between calls, this session holds nothing.

            Nothing here reads the screen beyond where the cursor is. What is at a point is the \
            caller's to know.
            """)

    @OptionGroup var service: ServiceOption

    /// What a client's initialize tells it about pairing this server with eyes': the
    /// shared screen points and the look-act-look loop. A copy of docs/mcp-instructions.txt,
    /// which eyes' server carries too: the packages link nothing of each other's, so each
    /// holds the text, and a test in each holds it to the file. [LAW:one-source-of-truth]
    static let instructions = """
        vhid and eyes are two MCP servers that work as a pair. eyes reads the screen: what is in front, and where text is. vhid drives a virtual keyboard and mouse that macOS takes for hardware. A client with only one of them is half the pair; both come with vhid, served by `vhid mcp` and `eyes mcp`.

        Every point either server prints or takes is the same screen point. The point eyes `find` prints is the point vhid `click` takes, as printed: no scaling, no offset, negative on a display left of or above the main one.

        Neither server decides anything. `click` presses whatever is at the point it is given, `type` types into whatever has keyboard focus, and `find` reports what is on screen, not whether an act did what was meant. So work in a loop:

        1. Look with eyes: `windows` for what is in front, `find` for where the text is.
        2. Act with vhid on what you saw.
        3. Look again at the same place. `find` with `until` and a `timeout` waits for the change; do not sleep and retry.

        Done means a look after the act showed the change. An act's answer says the act happened, not what it did.
        """

    /// The server as a client's initialize finds it, with `tools` attached to run against
    /// `installation`, each call held `underway` on the transport it will be started on,
    /// carried by `flights` until it and its record are done, and recorded as one
    /// invocation to `export` - after its answer, which does not wait on a collector.
    static func server(_ tools: [VerbTool] = Tools.all, on installation: Installation, over transport: AnsweringTransport,
                       recordingTo export: EventExport, carriedBy flights: Flights) async -> Server {
        let server = Server(name: "vhid", version: Version.current, instructions: instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        let turns = Turns()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools.map(\.tool)) }
        let hand: @Sendable (InvocationRecord) async -> Void = { record in await flights.launch { await export.export(record) } }
        await server.withMethodHandler(CallTool.self) { request in try await flights.carry {
            let arrived = ContinuousClock.now
            // Recorded under the method, not the name: a name the client made up is not a
            // verb, and would make one event per made-up name. The error says which.
            guard let verb = tools.first(where: { $0.tool.name == request.name }) else {
                let refusal = MCPError.invalidParams("there is no tool called \(request.name.debugDescription)")
                return try await Invocation.record(CallTool.name, via: .mcp, to: hand) { _ in throw refusal }
            }
            // A verb that could not do what it was asked is a tool error, whose words the
            // model reads; a protocol error is for a request that named no tool at all. A
            // call the client withdrew is answered like any other, and the transport drops
            // the answer, as the MCP spec says a cancelled request's is. What the verb said on
            // the way out still goes to stderr, because it can be the one report of what the
            // verb had already done when it was withdrawn. [LAW:no-silent-failure]
            return try await transport.underway {
                do {
                    let said = try await Invocation.record(request.name, via: .mcp, to: hand) { _ in
                        try await turns.take {
                            Invocation.set(.queuedMilliseconds, .double((ContinuousClock.now - arrived) / .milliseconds(1)))
                            return try await verb.call(request.arguments ?? [:], on: installation)
                        }
                    }
                    return .init(content: [.text(text: said, annotations: nil, _meta: nil)], isError: false)
                } catch where Task.isCancelled {
                    FileHandle.standardError.write(Data("vhid: \(request.name) withdrawn: \(error.reported)\n".utf8))
                    return .init(content: [.text(text: "withdrawn: \(error.reported)", annotations: nil, _meta: nil)], isError: true)
                } catch {
                    return .init(content: [.text(text: error.reported, annotations: nil, _meta: nil)], isError: true)
                }
            }
        } }
        return server
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

        try await Self.serve(on: installation, over: AnsweringTransport(StdioTransport(output: protocolOut)), recordingTo: .configured())
    }

    /// Serves `tools` over `transport` until the client hangs up or the serving task is
    /// cancelled, as Control-C and SIGTERM cancel it. A cancel withdraws every call owed,
    /// so each one stops as a client's cancel would stop it, and ends the session. Returns
    /// once every call has ended and every record is sent, throwing if it was cancelled.
    ///
    /// The cancel has to be carried in by hand: the SDK serves from a task of its own,
    /// which no cancel of this one reaches.
    static func serve(_ tools: [VerbTool] = Tools.all, on installation: Installation, over transport: AnsweringTransport,
                      recordingTo export: EventExport) async throws {
        let flights = Flights()
        let server = await server(tools, on: installation, over: transport, recordingTo: export, carriedBy: flights)
        try await server.start(transport: transport)
        await withTaskCancellationHandler {
            await server.waitUntilCompleted()
        } onCancel: {
            Task {
                await transport.withdrawEverything()
                await server.stop()
            }
        }
        await flights.landed()
        try Task.checkCancellation()
    }
}

/// What the server has under way and must see done before the process exits: tool calls
/// still running when the client hung up, and the records of calls already answered.
///
/// [LAW:nothing-unseen] Without it, a client that closed stdin mid-`type` would end the
/// process under the keystrokes still going out, and they would leave no record.
actor Flights {
    private var underway = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `body`, counted as under way until it returns.
    nonisolated func carry<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await depart()
        do {
            let done = try await body()
            await arrive()
            return done
        } catch {
            await arrive()
            throw error
        }
    }

    /// Starts `work` in a task of its own, counted as under way until it finishes.
    func launch(_ work: @escaping @Sendable () async -> Void) {
        depart()
        Task { await work(); arrive() }
    }

    /// Returns once nothing is under way.
    func landed() async {
        guard underway > 0 else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func depart() { underway += 1 }

    private func arrive() {
        underway -= 1
        guard underway == 0 else { return }
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// One tool call at a time.
///
/// **Why: the SDK runs every request in a task of its own.** Two calls sent together - a
/// click and a type in one turn of an agent's - would reach for the daemon at once, and it
/// serves one client: the second came back refused as busy, by this very process. Taking
/// turns makes the session one client again, and no two calls interleave report by report.
///
/// **Not the order they were sent in.** A call's turn is taken when its handler reaches
/// this actor, and the SDK's handlers race here from the shared pool, so two calls sent
/// together can take their turns either way round. JSON-RPC promises no order among
/// requests in flight together, and neither does this: a caller that needs one call after
/// another waits for the first one's answer, which is the one order a client can see.
/// [LAW:no-ambient-temporal-coupling] Exclusion is this actor's to own; order is the caller's.
actor Turns {
    private var last: Task<Void, Never>?

    /// Runs `call` once every call that took its turn before this one has finished. A
    /// cancelled caller cancels its call, waiting or running.
    func take<T: Sendable>(_ call: @escaping @Sendable () async throws -> T) async throws -> T {
        let before = last
        let turn = Task {
            await before?.value
            try Task.checkCancellation()
            return try await call()
        }
        last = Task { _ = await turn.result }
        return try await withTaskCancellationHandler { try await turn.value } onCancel: { turn.cancel() }
    }
}
