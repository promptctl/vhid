import MCP
import Testing
@testable import EyesCommand

/// What `eyes mcp` offers, asked through a client over an in-memory transport.
@Suite struct McpTests {
    /// A client connected to the server, and the server to stop once `body` is done.
    private func connected<T>(_ body: (Client) async throws -> T) async throws -> T {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let server = await Mcp.server()
        try await server.start(transport: serverSide)
        defer { Task { await server.stop() } }
        let client = Client(name: "test", version: "0")
        _ = try await client.connect(transport: clientSide)
        return try await body(client)
    }

    @Test func theToolsAreListedAndReadOnly() async throws {
        let tools = try await connected { try await $0.listTools().tools }
        #expect(tools.map(\.name) == ["windows"])
        #expect(tools.allSatisfy { $0.annotations.readOnlyHint == true })
    }

    /// The tool answers with what the verb prints, scope line first.
    @Test func windowsAnswersWithTheVerbsScopeLine() async throws {
        let (content, isError) = try await connected { try await $0.callTool(name: "windows", arguments: [:]) }
        guard case .text(let said, _, _) = content.first else { Issue.record("no text: \(content)"); return }
        #expect(isError != true, "\(said)")
        #expect(said.components(separatedBy: "\n").first?.contains("front to back") == true, "\(said)")
        #expect(said.contains("On screen only: minimized, hidden and other-Space windows were never looked at."))
    }

    /// Refusals come back as tool errors in the model's words, not as ignored arguments.
    @Test func argumentsItWillNotActOnAreToolErrors() async throws {
        for (arguments, expected): ([String: Value], String) in [
            (["owner": ""], "owner was given an empty value, which would filter out every window."),
            (["owner": 3], "owner is 3, and it takes a string"),
            (["own": "Safari"], "own is not an argument this tool takes: it takes owner"),
        ] {
            let (content, isError) = try await connected { try await $0.callTool(name: "windows", arguments: arguments) }
            guard case .text(let said, _, _) = content.first else { Issue.record("no text: \(content)"); continue }
            #expect(isError == true)
            #expect(said.hasPrefix(expected), "\(said)")
        }
    }
}
