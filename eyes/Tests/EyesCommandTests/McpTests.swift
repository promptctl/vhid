import Eyes
import MCP
import Testing
@testable import EyesCommand

/// What `eyes mcp` offers, asked through a client over an in-memory transport, with a
/// listing written here in place of the window server.
@Suite struct McpTests {
    private static let listing = WindowListing(
        windows: [
            Window(id: 1, owner: "Safari", pid: 400, frame: ScreenRect(x: 0, y: 33, width: 1512, height: 949), layer: 0),
            Window(id: 2, owner: "Finder", pid: 401, frame: ScreenRect(x: -800, y: 0, width: 800, height: 600), layer: 0),
        ],
        excluded: [])

    /// A client connected to a server over `listing`, both torn down before this returns.
    private func connected<T>(_ body: (Client) async throws -> T) async throws -> T {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let server = await Mcp.server(EyesTools.all(windows: { Self.listing }, displays: { DisplaysCommandTests.desk }))
        try await server.start(transport: serverSide)
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

    @Test func theToolsAreListedAndReadOnly() async throws {
        let tools = try await connected { try await $0.listTools().tools }
        #expect(tools.map(\.name) == ["windows", "displays"])
        #expect(tools.allSatisfy { $0.annotations.readOnlyHint == true })
    }

    /// The tool answers with exactly what the verb prints. [LAW:one-source-of-truth]
    @Test func windowsAnswersWithTheVerbsReport() async throws {
        for owner: Value in [.null, "finder"] {
            let (said, isError) = try await call(owner.isNull ? [:] : ["owner": owner])
            #expect(isError != true)
            #expect(said == Windows.report(Self.listing, owner: owner.stringValue))
        }
        #expect(try await call(["owner": .null]).0 == Windows.report(Self.listing, owner: nil))
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
}
