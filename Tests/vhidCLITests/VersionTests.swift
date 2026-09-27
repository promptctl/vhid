import Foundation
import MCP
import Testing
import Version
@testable import vhid

/// One version, reported the same way by every surface that reports one, and the value
/// scripts/version derives from VERSION and git.
@Suite struct VersionTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized

    /// What scripts/version prints for `repo`.
    static func script(in repo: URL) throws -> String {
        try Self.run(root.appending(path: "scripts/version").path(), [repo.path()], in: repo)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(executable) \(arguments)")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theBuildReportsWhatTheScriptDerivesForThisTree() throws {
        #expect(Version.current == (try Self.script(in: Self.root)))
    }

    @Test func dashDashVersionPrintsIt() {
        #expect(Vhid.configuration.version == Version.current)
    }

    @Test func mcpInitializeReportsIt() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let server = McpCommand.server()
        try await server.start(transport: serverSide)
        let result = try await Client(name: "test", version: "0").connect(transport: clientSide)
        await server.stop()
        #expect(result.serverInfo.name == "vhid")
        #expect(result.serverInfo.version == Version.current)
    }

    /// A scratch repo holding VERSION and one commit.
    static func repo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appending(path: "vhid-version-\(UUID())")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "1.2.3\n".write(to: repo.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        for arguments in [
            ["init", "-q"], ["add", "VERSION"],
            ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "v"],
        ] {
            try Self.run("/usr/bin/git", arguments, in: repo)
        }
        return repo
    }

    @Test func aTaggedCleanTreeIsTheReleaseAndAnythingElseIsADevBuildOfItsCommit() throws {
        let repo = try Self.repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let commit = try Self.run("/usr/bin/git", ["rev-parse", "--short", "HEAD"], in: repo)
        #expect(try Self.script(in: repo) == "1.2.3-dev+\(commit)")
        try Self.run("/usr/bin/git", ["tag", "v1.2.3"], in: repo)
        #expect(try Self.script(in: repo) == "1.2.3")
        try "1.2.3 \n".write(to: repo.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        #expect(try Self.script(in: repo) == "1.2.3-dev+\(commit)")
    }

    @Test func withNoGitItIsADevBuild() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vhid-version-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "1.2.3\n".write(to: dir.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        #expect(try Self.script(in: dir) == "1.2.3-dev")
    }
}
