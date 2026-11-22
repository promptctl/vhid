import ApplicationServices
import ChildProcess
import CoreGraphics
import Darwin
import Seeing
import Foundation
import Responsibility
import Telemetry

/// The two privacy grants eyes' readers need.
///
/// macOS does not charge a grant to the process reading: it charges it to the process
/// responsible for it - the terminal a command was typed into, the client that started
/// `vhid mcp`. So every answer here names that app, because "grant it to vhid" is advice
/// nobody can follow. Measured: from iTerm2, `CGPreflightScreenCaptureAccess()` answers for iTerm2
/// even in an unsigned binary built a moment earlier.
public enum Grant: String, CaseIterable, Sendable {
    case screenRecording
    case accessibility

    /// The pane's name, as System Settings shows it.
    public var name: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    /// The reader that cannot look without it. [LAW:one-source-of-truth] The one mapping
    /// between readers and grants that every sentence naming a reader's grant is built
    /// from; each reader's own `grant` is held to it by its gate test.
    public var reader: SourceKind {
        switch self {
        case .screenRecording: .pixels
        case .accessibility: .tree
        }
    }

    public var pane: String { "System Settings > Privacy & Security > \(name)" }

    /// Where a refusal points for the app that has to hold a grant, which is not this
    /// binary but whichever app macOS charges it to: a terminal, an agent's app.
    public static let holderNamedBy = "`vhid doctor` or `eyes grants`"

    /// Whether this process holds it, read without ever putting a dialog on screen.
    ///
    /// Reading Accessibility files the responsible app into the Accessibility list,
    /// switched off. That is the list the user turns it on in, so it is left to happen.
    func heldHere() -> Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// Raises macOS's own dialog. macOS shows it once per app; after an answer, only the
    /// switch in the pane changes it. [LAW:effects-at-boundaries] Asking is apart from
    /// reading so that no read can ever prompt.
    public func ask() {
        switch self {
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        // The option key is spelled out: `kAXTrustedCheckOptionPrompt` is a C global Swift
        // 6 will not read from a nonisolated context, and this is its documented value.
        case .accessibility: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }
}

/// Whether a grant is held, asked by a reader before it looks. In the binary it is a
/// `SharedReading`, because a long-lived process's own answer goes stale; see `GrantReading.here()`.
public typealias Gate = @Sendable (Grant) async throws -> Bool

/// One process's readings, shared by every gate: a reading that finished less than `fresh`
/// ago answers them all, so a merged look and a wait's polls take one reading, not one each.
/// A reading still being taken is waited on, however long it takes, never taken twice. A
/// failed reading is shared like any other, and says itself to every gate it answers.
/// [LAW:no-silent-failure]
public actor SharedReading {
    private let take: @Sendable () async throws -> GrantReading
    private let fresh: Duration
    /// The latest reading, and when it finished; nil while it is still being taken.
    private var latest: (reading: Task<GrantReading, any Error>, finished: ContinuousClock.Instant?)?

    public init(fresh: Duration = .seconds(1), take: @escaping @Sendable () async throws -> GrantReading) {
        self.fresh = fresh
        self.take = take
    }

    /// One event per gate asked: which grant, whether its reading was shared or taken,
    /// and how long the gate waited. The child's own event is `grant_child`, on this trace.
    /// [LAW:nothing-unseen]
    public func holds(_ grant: Grant) async throws -> Bool {
        try await Telemetry.unit("grant_reading", result: { $0 ? "held" : "not_held" }) {
            Telemetry.note(.grant, .string(grant.rawValue))
            return try await reading(grant)
        }
    }

    private func reading(_ grant: Grant) async throws -> Bool {
        if let latest, latest.finished.map({ ContinuousClock.now - $0 < fresh }) ?? true {
            Telemetry.note(.reading, "shared")
            return try await Self.waited(latest.reading).holds(grant)
        }
        Telemetry.note(.reading, "taken")
        taking += 1
        let reading = Task { [take, taking] in
            // Stamped when the reading ends, not when a gate stops waiting: a cancelled
            // gate leaves the reading running, and it is still the one being taken.
            defer { Task { await self.finished(taking) } }
            return try await take()
        }
        latest = (reading, nil)
        return try await Self.waited(reading).holds(grant)
    }

    /// Which reading is the latest, counted, so an older one ending does not stamp it.
    private var taking = 0

    private func finished(_ reading: Int) {
        if reading == taking { latest?.finished = .now }
    }

    /// A shared reading's answer, given up the moment the asking task is cancelled while
    /// the reading goes on for every other gate waiting on it.
    private static func waited(_ reading: Task<GrantReading, any Error>) async throws -> GrantReading {
        let (answer, say) = AsyncThrowingStream<GrantReading, any Error>.makeStream()
        let relay = Task {
            do { say.yield(try await reading.value); say.finish() } catch { say.finish(throwing: error) }
        }
        defer { relay.cancel() }
        for try await taken in answer { return taken }
        throw CancellationError()
    }
}

/// Which grants are held, at one moment.
public struct GrantReading: Sendable, Equatable {
    private let held: [Grant: Bool]

    /// [LAW:types-are-the-program] Built from an answer for every grant, so no reading can
    /// leave one out and have it read as "not granted".
    public init(_ holds: (Grant) -> Bool) {
        held = Dictionary(uniqueKeysWithValues: Grant.allCases.map { ($0, holds($0)) })
    }

    public func holds(_ grant: Grant) -> Bool { held[grant]! }

    /// This process's own reading. A long-lived process keeps the first Screen Recording
    /// answer it got - measured on macOS 15, a process read a grant "off" for 24 s after
    /// it was allowed and asked tccd nothing meanwhile - so this is only ever the answer
    /// of a process started to give it; see `taken(by:)`.
    public static func here() -> GrantReading {
        GrantReading { $0.heldHere() }
    }

    /// How a reading process exits: 0 when this reading holds every grant, `lacking` when it
    /// does not. A script reads this, as a parent reads `line`, so no script parses the line.
    /// [LAW:one-source-of-truth] The verdict is the reading's own.
    public var exitStatus: Int32 { Grant.allCases.allSatisfy(holds) ? 0 : Self.lacking }

    /// The exit status of a reading process whose reading lacks a grant: apart from
    /// ArgumentParser's own failure (1) and validation (64), so a failed run is not read as one.
    public static let lacking: Int32 = 3

    /// The line a reading process prints and `init(line:)` reads back.
    public var line: String {
        Grant.allCases.map { "\($0.rawValue)=\(holds($0))" }.joined(separator: " ")
    }

    /// [LAW:parse-dont-validate] The one place a printed line becomes a reading: every
    /// grant named once, true or false, and nothing else.
    public init(line: String) throws(GrantReadingFailure) {
        var held: [Grant: Bool] = [:]
        for field in line.split(separator: " ") {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let grant = Grant(rawValue: pair[0]), held[grant] == nil,
                  let value = Bool(pair[1])
            else { throw GrantReadingFailure("unreadable grants line \"\(line)\"") }
            held[grant] = value
        }
        guard held.count == Grant.allCases.count else { throw GrantReadingFailure("unreadable grants line \"\(line)\"") }
        self.init { held[$0]! }
    }

    /// A fresh reading: `reader` run with `arguments` as a child of this process, so macOS
    /// credits it to the same responsible app and it queries tccd anew.
    ///
    /// - Parameter deadline: past this the child is stuck, and is killed. A read takes
    ///   milliseconds; a new binary's first launch is checked by macOS first.
    /// One event per child, however its gates end: how long the child took and why it failed,
    /// apart from how long any gate waited on it. [LAW:nothing-unseen]
    /// Throws `GrantReadingFailure`, or `CancellationError` when the reading was withdrawn,
    /// which is a cancellation, recorded and passed on as one.
    public static func taken(by reader: URL, _ arguments: [String], within deadline: Duration = .seconds(10)) async throws -> GrantReading {
        try await Telemetry.unit("grant_child") { try await child(reader, arguments, within: deadline) }
    }

    private static func child(_ reader: URL, _ arguments: [String], within deadline: Duration) async throws -> GrantReading {
        // The child's records, if it makes any, belong under this reading's span.
        let command = Command(reader.path, arguments, environment: Telemetry.childEnvironment())
        let ran = try await reading(within: deadline) { deadline in Result { try command.run(by: deadline) } }
        let output: Command.Output
        do { output = try ran.get() } catch { throw GrantReadingFailure("\(error)") }
        guard case .exited(let status) = output.ending, [0, GrantReading.lacking].contains(status) else {
            let how = switch output.ending { case .exited(let code): "exited \(code)"; case .signalled(let code): "crashed with signal \(code)" }
            let complaint = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GrantReadingFailure("\(reader.path) \(how)\(complaint.isEmpty ? "" : ": \(complaint)")")
        }
        return try GrantReading(line: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct GrantReadingFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The app macOS charges this process's grants to.
public struct Holder: Sendable, Equatable {
    /// The name the pane lists it under.
    public let name: String
    /// The app bundle, or the bare executable when the responsible process is not in one.
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    /// The app enclosing `executable`: the outermost `.app` on its path, which is the one
    /// the pane lists - a helper inside an app is charged to that app.
    public init(executable: String) {
        let parts = executable.split(separator: "/", omittingEmptySubsequences: false)
        if let app = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            self.init(name: String(parts[app].dropLast(".app".count)), path: parts[...app].joined(separator: "/"))
        } else {
            self.init(name: String(parts.last ?? Substring(executable)), path: executable)
        }
    }

    /// The responsible process of this one, as tccd attributes it. One event per naming,
    /// carrying the executable the attribution named. [LAW:nothing-unseen]
    public static func current() async throws(GrantReadingFailure) -> Holder {
        try await Telemetry.unit("holder") { () throws(GrantReadingFailure) -> Holder in
            let executable = try attributed()
            Telemetry.note(.executable, .string(executable))
            return named(executable)
        }
    }

    /// The executable the attribution records: the one the responsible process was spawned
    /// from, which is what tccd matches a grant against. [LAW:one-source-of-truth] The
    /// responsible pid's current image is not it - over ssh, sshd-keygen-wrapper is spawned
    /// and then execs sshd-session, and the grant is held under the wrapper.
    ///
    /// A path is all the pane can list, so an attribution naming none is said, never printed
    /// as a blank app. [LAW:no-silent-failure]
    private static func attributed() throws(GrantReadingFailure) -> String {
        var token = audit_token_t()
        let read = responsibility_self_audit_token(&token)
        guard read == KERN_SUCCESS else {
            throw GrantReadingFailure("this process cannot read its own audit token: \(String(cString: mach_error_string(read)))")
        }
        guard let identity = responsibility_get_attribution_for_audittoken(&token, 0) else {
            throw GrantReadingFailure("macOS gave no attribution for this process")
        }
        defer { responsibility_identity_release(identity) }
        guard let path = responsibility_identity_get_binary_path(identity), path.pointee != 0 else {
            throw GrantReadingFailure("macOS's attribution for this process names no executable")
        }
        return String(cString: path)
    }

    /// The holder `executable` makes, by the name the pane lists it under.
    private static func named(_ executable: String) -> Holder {
        let found = Holder(executable: executable)
        // The pane lists an app by its Finder name, which its file name need not be; that name
        // carries ".app" when Finder shows every extension, and the pane never does.
        let listed = FileManager.default.displayName(atPath: found.path)
        return found.path.hasSuffix(".app")
            ? Holder(name: listed.hasSuffix(".app") ? String(listed.dropLast(".app".count)) : listed, path: found.path)
            : found
    }
}
