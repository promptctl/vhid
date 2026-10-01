import DriverExtension
import Foundation
import Installations
import OwnThread
import Testing

@testable import vhidd

/// The plist the pkg installs, held to the argv this daemon reads.
///
/// `scripts/launchd-plist` is the one writer of that plist, and `scripts/make-pkg` runs it
/// with the service the packed CLI names. A plist whose Label, MachServices key and
/// `--service` disagree is a daemon listening under one name while clients dial another,
/// and it surfaces only as a vhidd nobody can reach - so the writer's output is read back
/// through the daemon's own parser rather than matched as text. [LAW:behavior-not-structure]
@Suite(.ownThread) struct LaunchdPlistTests {
    /// Carries `&` and `<`, the two characters that leave a plist unparseable when written
    /// bare, so an escape the writer dropped fails the parse.
    static let daemon = "/Library/A & B/<vhidd>"

    /// vhid's two, and one name from the open set that carries the same characters, so the
    /// escaping of the three places the service is written is exercised too.
    static let installations = Installation.vhids + [Installation(service: "com.example.a&b<c")!]

    @Test(arguments: installations)
    func theDaemonRegistersUnderTheNameLaunchdStartsItAs(installation: Installation) throws {
        let plist = try Self.written(service: installation.service, daemon: Self.daemon)
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        let label = try #require(plist["Label"] as? String)
        let services = try #require(plist["MachServices"] as? [String: Bool])

        #expect(arguments == [Self.daemon, "--service", installation.service])
        // serviceArgument refuses a missing, doubled or flag-valued `--service`, but not a
        // `--flavor` beside a good one - the line below is what refuses that.
        #expect(serviceArgument(arguments) == installation)
        #expect(!arguments.contains("--flavor"))
        #expect(installation.launchdLabel == label)
        #expect(services == [installation.service: true])
        // The daemon exits 0 exactly when starting again would not help.
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
    }

    /// Runs the writer and parses what it wrote. [LAW:no-silent-failure] A writer that
    /// failed or wrote nothing is a thrown error carrying what it said, not an empty
    /// dictionary.
    static func written(service: String, daemon: String) throws -> [String: Any] {
        let script = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/launchd-plist")
        let output = try Command(script.path, service, daemon).run()
        try #require(output.status == 0, "scripts/launchd-plist exited \(output.status): \(output.merged)")
        let parsed = try PropertyListSerialization.propertyList(from: Data(output.stdout.utf8), format: nil)
        return try #require(parsed as? [String: Any])
    }
}
