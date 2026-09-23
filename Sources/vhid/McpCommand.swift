import ArgumentParser
import Darwin
import Input
import MCP
import System

/// The verbs as MCP tools, over stdio, for an agent that drives a Mac in one session
/// rather than a process per keystroke.
struct McpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the verbs as MCP tools over stdin and stdout.",
        discussion: """
            Newline-delimited JSON-RPC on stdin and stdout, and nothing else on stdout: every \
            diagnostic goes to stderr. The tools are type, press, click, move, scroll, drag and cursor. \
            They take what the verbs of the same name take and answer with what those verbs print.

            Tool calls run one at a time, in turn, even when a client sends them together. Each \
            connects to the daemon and disconnects when it returns. The daemon serves \
            one client at a time, so a session that held its connection open would refuse every other \
            caller for as long as it ran: a vhid click from a shell, and every other agent's session. \
            Between calls, this session holds nothing.

            Nothing here reads the screen beyond where the cursor is. What is at a point is the \
            caller's to know.
            """)

    @OptionGroup var service: ServiceOption

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

        let server = Server(name: "vhid", version: "0", capabilities: .init(tools: .init(listChanged: false)))
        let turns = Turns()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: Tools.all.map(\.tool)) }
        await server.withMethodHandler(CallTool.self) { request in
            guard let verb = Tools.all.first(where: { $0.tool.name == request.name }) else {
                throw MCPError.invalidParams("there is no tool called \(request.name.debugDescription)")
            }
            // A verb that could not do what it was asked is a tool error, whose words the
            // model reads; a protocol error is for a request that named no tool at all. A
            // call the client withdrew is neither: it is thrown as a cancellation, which
            // the SDK answers with nothing, as the MCP spec says a cancelled request is.
            do {
                let said = try await turns.take { try await verb.call(request.arguments ?? [:], on: installation) }
                return .init(content: [.text(text: said, annotations: nil, _meta: nil)], isError: false)
            } catch where Task.isCancelled {
                throw CancellationError()
            } catch {
                return .init(content: [.text(text: error.reported, annotations: nil, _meta: nil)], isError: true)
            }
        }
        try await server.start(transport: AnsweringTransport(StdioTransport(output: protocolOut)))
        await server.waitUntilCompleted()
    }
}

/// One tool call at a time, in the order they take their turns.
///
/// **Why: the SDK runs every request in a task of its own.** Two calls sent together - a
/// click and a type in one turn of an agent's - would reach for the daemon at once, and it
/// admits one client: the second came back refused as busy, by this very process. Taking
/// turns makes the session one client again, and it keeps what a caller sent in order on
/// the screen, where two calls interleaving report by report would mean neither.
/// [LAW:no-ambient-temporal-coupling] The order is this actor's to own.
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
