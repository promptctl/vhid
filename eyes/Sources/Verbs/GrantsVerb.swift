import ArgumentParser
import Foundation
import Grants
import Telemetry

/// Whether the readers' grants are held, and by which app, asked before a reading needs
/// them rather than learned from a refusal halfway through a task.
public struct GrantsVerb: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "grants",
        abstract: "Say whether Screen Recording and Accessibility are granted, and which app macOS charges them to.",
        discussion: """
            Reads without prompting. The grants belong to the app responsible for eyes - the \
            terminal, or the client running eyes mcp - and that is the app to switch on.
            """
    )

    @Flag(help: "Raise macOS's dialog for each missing grant. macOS shows it once per app; run eyes grants again once it is answered.")
    var ask = false

    public func run() async throws {
        let (reading, holder) = try await Self.look()
        // The dialogs return before anyone answers them, so there is nothing new to read yet.
        let asked = ask ? Grant.allCases.filter { !reading.holds($0) } : []
        asked.forEach { $0.ask() }
        print(Self.report(reading, holder: holder, asked: asked))
    }

    /// A fresh reading and the app it is charged to, as one unit, so the holder named and the
    /// reading it was reported with share a trace. The verb and the MCP tool both ask here.
    /// [LAW:nothing-unseen] [LAW:one-source-of-truth]
    static func look(reading: () async throws -> GrantReading = { try await reading() }) async throws -> (GrantReading, Holder) {
        try await Telemetry.unit("grants") { (try await reading(), try await Holder.current()) }
    }

    /// A fresh reading, from a child of this process. [LAW:no-ambient-temporal-coupling]
    /// A long-lived MCP server keeps its first Screen Recording answer, so it never reads
    /// its own; a child asks tccd anew every time.
    static func reading() async throws -> GrantReading {
        guard let own = Bundle.main.executableURL else {
            throw GrantReadingFailure("this process cannot name its own executable to start a reading")
        }
        return try await GrantReading.taken(by: own, [ReadGrants.configuration.commandName!])
    }

    /// A fresh reading as its report, asking for nothing: what `vhid doctor` says of the
    /// screen beside the devices. A reading that fails is said in its place, so it never
    /// takes the device rows with it. [LAW:no-silent-failure]
    public static func reported() async -> String {
        do {
            let (reading, holder) = try await look()
            return report(reading, holder: holder, asked: [])
        } catch {
            return "The grants could not be read: \(error)"
        }
    }

    /// The scope line and a row per grant: what the verb prints and what `vhid doctor`
    /// says. Pure, so both are tested with readings a test wrote.
    /// [LAW:one-source-of-truth] [LAW:effects-at-boundaries]
    static func report(_ reading: GrantReading, holder: Holder, asked: [Grant]) -> String {
        let scope = "\(Grant.allCases.count) grants, read before any dialog."
            + " macOS charges them to \(holder.name) (\(holder.path)), the app responsible for this process;"
            + " that is the app to switch on."
        // The dialog comes once per app, so one that never appears is the pane's to change.
        // [LAW:no-silent-failure]
        let after = asked.isEmpty ? [] : [
            "Asked for \(asked.map(\.name).joined(separator: " and ")): answer macOS's dialog, then run eyes grants to read again."
                + " If no dialog appeared, macOS already has an answer from \(holder.name), and only its switch in the pane changes it.",
        ]
        return ([scope] + Grant.allCases.map { row($0, held: reading.holds($0), holder: holder) } + after)
            .joined(separator: "\n")
    }

    /// One grant: its name, held or not, the reader it serves, and where to fix it.
    static func row(_ grant: Grant, held: Bool, holder: Holder) -> String {
        "\(grant.name)\t\(held ? "granted" : "not granted")\t\(grant.reader.rawValue)"
            + (held ? "" : "\tturn on \(holder.name) in \(grant.pane)")
    }
}

/// The child's half of a fresh grant reading: this process's own answer, printed as one
/// line for the process that started it. Every executable that reads grants lists it, so
/// `GrantsVerb.reading` can start its own executable whichever that is. Hidden, because it
/// is the mechanism of a reading, not a question a person asks.
/// [LAW:one-source-of-truth] Every reading is one of these.
public struct ReadGrants: ParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(commandName: "read-grants", shouldDisplay: false)

    public func run() {
        print(GrantReading.here().line)
    }
}
