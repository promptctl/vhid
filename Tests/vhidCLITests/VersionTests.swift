import Foundation
import Installations
import MCP
import OwnThread
import Testing
import Version
@testable import vhid

/// One version, reported the same way by every surface that reports one, and the value
/// scripts/version derives from VERSION and git.
@Suite(.ownThread) struct VersionTests {
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
        // The scratch repos are this suite's own: no global hooks, signing or identity.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(executable) \(arguments)")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read against VERSION rather than against the tree's git state now, which can have
    /// moved on since the build stamped it.
    @Test func theBuildReportsVersionsValueOrADevBuildOfIt() throws {
        let base = try Self.run(Self.root.appending(path: "scripts/version").path(), ["--base"], in: Self.root)
        let commit = Version.current.split(separator: "-dev+", maxSplits: 1).dropFirst().first
        #expect(
            Version.current == base || Version.current == "\(base)-dev"
                || (Version.current.hasPrefix("\(base)-dev+") && commit?.allSatisfy(\.isHexDigit) == true))
    }

    @Test func dashDashVersionPrintsIt() {
        #expect(Vhid.configuration.version == Version.current)
    }

    @Test func mcpInitializeReportsIt() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let transport = AnsweringTransport(serverSide)
        let server = await McpCommand.server(on: Installation(service: "ai.promptctl.vhid.tests.nobody")!, over: transport)
        try await server.start(transport: transport)
        let result: Initialize.Result
        do {
            result = try await Client(name: "test", version: "0").connect(transport: clientSide)
        } catch {
            await server.stop()
            throw error
        }
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
            ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "v"],
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
        try "".write(to: repo.appending(path: "untracked.swift"), atomically: true, encoding: .utf8)
        #expect(try Self.script(in: repo) == "1.2.3-dev+\(commit)")
        try FileManager.default.removeItem(at: repo.appending(path: "untracked.swift"))
        try "1.2.3 \n".write(to: repo.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        #expect(try Self.script(in: repo) == "1.2.3-dev+\(commit)")
    }

    @Test func aTagThatOnlyLooksLikeItIsNotTheRelease() throws {
        let repo = try Self.repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.run("/usr/bin/git", ["tag", "v1-2-3"], in: repo)
        #expect(try Self.script(in: repo).hasPrefix("1.2.3-dev+"))
    }

    @Test func aVersionThatIsNotDottedNumbersBuildsNothing() throws {
        let repo = try Self.repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "0.1\"0\n".write(to: repo.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = Self.root.appending(path: "scripts/version")
        process.arguments = [repo.path()]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
    }

    @Test func withNoGitItIsADevBuild() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vhid-version-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "1.2.3\n".write(to: dir.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        #expect(try Self.script(in: dir) == "1.2.3-dev")
    }
}
