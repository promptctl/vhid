import Foundation
import Installations
import Testing

@testable import vhidd

/// The plist the pkg installs, held to the argv this daemon reads.
///
/// `scripts/launchd-plist` is the one writer of that plist, and `scripts/make-pkg` runs it
/// with the service the packed CLI names. A plist whose Label, MachServices key and
/// `--service` disagree is a daemon listening under one name while clients dial another,
/// and it surfaces only as a helper nobody can reach - so the writer's output is read back
/// through the daemon's own parser rather than matched as text. [LAW:behavior-not-structure]
struct LaunchdPlistTests {
    /// The daemon path carries every character XML reserves, so an escape the writer
    /// dropped is a plist that does not parse rather than one that happens to.
    static let daemon = "/Library/A & B/<vhidd> \"x\""

    @Test(arguments: Installation.vhids)
    func theDaemonRegistersUnderTheNameLaunchdStartsItAs(installation: Installation) throws {
        let plist = try Self.written(service: installation.service, daemon: Self.daemon)
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        let label = try #require(plist["Label"] as? String)
        let services = try #require(plist["MachServices"] as? [String: Bool])

        #expect(arguments.first == Self.daemon)
        // Refuses a missing, doubled or flag-valued `--service`, and the pre-rename
        // `--flavor` along with them, so a nil here is any of those shapes.
        let read = try #require(serviceArgument(arguments))
        #expect(read == installation)
        #expect(read.launchdLabel == label)
        #expect(Array(services.keys) == [installation.service])
        #expect(!arguments.contains("--flavor"))
    }

    /// Runs the writer and parses what it wrote. [LAW:no-silent-failure] A writer that
    /// failed or wrote nothing is a thrown error, not an empty dictionary.
    static func written(service: String, daemon: String) throws -> [String: Any] {
        let script = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/launchd-plist")
        let process = Process()
        process.executableURL = script
        process.arguments = [service, daemon]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "scripts/launchd-plist exited \(process.terminationStatus)")
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
