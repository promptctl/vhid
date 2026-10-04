import ArgumentParser
import DriverExtension
import Foundation
import Helper
import RecordingTie

/// Records the physical keyboard and mouse as a script `vhid play` replays.
///
/// The tap runs in a signed app bundle of its own, because Input Monitoring is granted to
/// the responsible process and a bundle is one a person can grant it to once, whatever
/// launched `vhid` (`docs/design/replay.md`, "The grant recording needs"). This command
/// refuses what would make a recording wrong, launches the app, turns the signal that stops
/// it into a message to the app, and prints what it sends back.
struct RecordCommand: AsyncParsableCommand {
    static let configuration = Help.record.configuration

    @OptionGroup var service: ServiceOption

    func run() async throws {
        // [LAW:parse-dont-validate] Every refusal the command can make is made before the
        // app is launched, so a refused recording leaves nothing running.
        try Self.refusal(holder: HelperConnection(installation: try service.installation()).status(),
                         system: Self.services(in: "system"), session: Self.services(in: "gui/\(getuid())")).map { throw $0 }
        // A stop that came before the app did launches none.
        try Task.checkCancellation()
        let listener = try TieListener()
        try Self.launch(app: try Self.app(), socket: listener.path)
        let app = try listener.accept(within: .seconds(10))
        switch try app.receive(FromApp.self) {
        case .recording?:
            FileHandle.standardError.write(Data("vhid record: recording; Control-C stops\n".utf8))
        case .refused(let reason)?:
            throw RecordRefusal.app(reason)
        case let other:
            throw TieFailure("the tap app's first word was \(other.map { "\($0)" } ?? "nothing"), not that it was recording")
        }
        // The stop is the command line's cancel. SIGINT is Control-C, whose own keys come
        // out of the recording; SIGTERM, or a cancel no signal made, ends it and drops
        // nothing. Either is answered by finishing, so the process exits as the recording
        // ended. A failed send is the app gone, which the read below reports. A second
        // signal ends the process, whose exit the app's pid watch sees.
        let signals = Invocation.current?.signals
        try await withTaskCancellationHandler {
            while let message = try app.receive(FromApp.self) {
                switch message {
                case .note(let note): FileHandle.standardError.write(Data("vhid record: \(note)\n".utf8))
                case .script(let script): print(script, terminator: ""); return
                case .recording, .refused: throw TieFailure("the tap app said \(message) while recording")
                }
            }
            throw TieFailure("the tap app ended without sending the recording")
        } onCancel: {
            signals?.answer()
            try? app.send(signals?.taken == SIGINT ? ToApp.stop : ToApp.end)
        }
    }

    /// Why a recording cannot start, from what was read: who holds the devices, and the
    /// launchd services loaded in the system domain and the person's session. nil when
    /// nothing stands in the way.
    static func refusal(holder: Int32?, system: [String], session: [String]) -> RecordRefusal? {
        if let holder { return .held(by: holder) }
        // The driver's own job is loaded under its bundle ID and the registry ID of its
        // service; every other org.pqrs job is Karabiner-Elements posting through the
        // same driver, whose output the recorder would drop as vhid's.
        let others = (system + session).filter { $0.hasPrefix("org.pqrs.") && !$0.hasPrefix(DriverProbe.bundleID + "-") }
        return others.isEmpty ? nil : .pqrsServices(others.sorted())
    }

    /// The labels `launchctl print <domain>` lists under services. [LAW:effects-at-boundaries]
    static func services(in domain: String) throws -> [String] {
        let printed = try Command("/bin/launchctl", "print", domain).run(by: .within(Command.limit))
        guard printed.status == 0 else {
            throw DriverUnreadable.toolFailed(tool: "launchctl print \(domain)", status: printed.status, complaint: printed.merged)
        }
        return try labels(inPrinted: printed.stdout, domain: domain)
    }

    /// The labels of a `launchctl print` domain record's services block: one per line,
    /// the label last after a pid and a status. [LAW:parse-dont-validate] A record with no
    /// such block is refused rather than read as one with no services, which would let
    /// Karabiner through.
    static func labels(inPrinted record: String, domain: String) throws -> [String] {
        let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
        guard let open = lines.firstIndex(of: "\tservices = {"), let close = lines[open...].firstIndex(of: "\t}") else {
            throw RecordRefusal.unreadable("`launchctl print \(domain)` printed no services block this build can read")
        }
        return lines[(open + 1)..<close].compactMap { $0.split(whereSeparator: \.isWhitespace).last.map(String.init) }
    }

    /// The tap app, where this build's copy is: the pkg's in libexec, and a working tree's
    /// in ~/Applications, where System Settings can add it to Input Monitoring - a bundle
    /// inside `.build` cannot be. Chosen the way `Installation.thisBuild` is, so a dev vhid
    /// never runs the installed tap or the other way round. [LAW:one-source-of-truth]
    #if DEBUG
    static let appPath = NSHomeDirectory() + "/Applications/vhid-record-dev.app"
    #else
    static let appPath = "/usr/local/libexec/vhid-record.app"
    #endif

    static func app() throws -> URL {
        guard FileManager.default.fileExists(atPath: appPath) else { throw RecordRefusal.noApp(appPath) }
        return URL(fileURLWithPath: appPath)
    }

    /// `open -n`, so every recording is a fresh instance with its own arguments, and `-g`,
    /// so the app never comes forward over what is being recorded.
    static func launch(app: URL, socket: String) throws {
        let opened = try Command("/usr/bin/open", "-n", "-g", app.path, "--args", socket, String(getpid())).run(by: .within(Command.limit))
        guard opened.status == 0 else { throw TieFailure("open could not launch \(app.path): \(opened.merged)") }
    }
}

enum RecordRefusal: Error, CustomStringConvertible, Equatable {
    case held(by: Int32)
    case pqrsServices([String])
    case noApp(String)
    case app(String)
    case unreadable(String)

    var description: String {
        switch self {
        case .held(let pid):
            "process \(pid) holds the devices; vhid record starts when nothing does, so vhid's own modifiers cannot be mistaken for the person's"
        case .pqrsServices(let labels):
            "these launchd services post through the same driver as vhid, so what they post would be dropped as vhid's: \(labels.joined(separator: ", ")). Quit Karabiner-Elements and run again"
        case .noApp(let path):
            "the tap app is not at \(path); build with make, or reinstall"
        case .app(let reason), .unreadable(let reason):
            reason
        }
    }
}
