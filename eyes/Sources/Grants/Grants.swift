import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// The two privacy grants eyes' readers need.
///
/// macOS does not charge a grant to eyes: it charges it to the process responsible for
/// eyes - the terminal a command was typed into, the client that started `eyes mcp`. So
/// every answer here names that app, because "grant it to eyes" is advice nobody can
/// follow. Measured: from iTerm2, `CGPreflightScreenCaptureAccess()` answers for iTerm2
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

    /// The reader that cannot look without it.
    public var reader: String {
        switch self {
        case .screenRecording: "pixels"
        case .accessibility: "tree"
        }
    }

    public var pane: String { "System Settings > Privacy & Security > \(name)" }

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

/// Which grants are held, at one moment.
public struct GrantReading: Sendable, Equatable {
    public let held: [Grant: Bool]

    public init(held: [Grant: Bool]) { self.held = held }

    /// This process's own reading. A long-lived process keeps the first Screen Recording
    /// answer it got - measured on macOS 15, a process read a grant "off" for 24 s after
    /// it was allowed and asked tccd nothing meanwhile - so this is only ever the answer
    /// of a process started to give it; see `taken(by:)`.
    public static func here() -> GrantReading {
        GrantReading(held: Dictionary(uniqueKeysWithValues: Grant.allCases.map { ($0, $0.heldHere()) }))
    }

    /// The line a reading process prints and `init(line:)` reads back.
    public var line: String {
        Grant.allCases.map { "\($0.rawValue)=\(held[$0] == true)" }.joined(separator: " ")
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
        self.init(held: held)
    }

    /// A fresh reading: `reader` run with `arguments` as a child of this process, so macOS
    /// credits it to the same responsible app and it queries tccd anew.
    ///
    /// - Parameter deadline: past this the child is stuck, and is killed. A read takes
    ///   milliseconds; a new binary's first launch is checked by macOS first.
    public static func taken(by reader: URL, _ arguments: [String], within deadline: Duration = .seconds(10)) async throws(GrantReadingFailure) -> GrantReading {
        let command = ([reader.path] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = reader
        process.arguments = arguments
        let output = Pipe(), complaint = Pipe()
        process.standardOutput = output
        process.standardError = complaint
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw GrantReadingFailure("\(command) did not start: \(error)") }
        // Waited for off the cooperative pool, which a stuck child must not hold.
        let (seconds, attoseconds) = deadline.components
        let finished = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                done.resume(returning: exited.wait(timeout: .now() + Double(seconds) + Double(attoseconds) / 1e18) == .success)
            }
        }
        guard finished else {
            kill(process.processIdentifier, SIGKILL)
            throw GrantReadingFailure("\(command) did not answer within \(deadline)")
        }
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let why = String(decoding: complaint.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let how = process.terminationReason == .uncaughtSignal ? "crashed with signal" : "exited"
            throw GrantReadingFailure("\(command) \(how) \(process.terminationStatus)\(why.isEmpty ? "" : ": \(why)")")
        }
        return try GrantReading(line: said)
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

    /// The responsible process of this one, as macOS attributes it.
    ///
    /// `responsibility_get_pid_responsible_for_pid` is the call tccd's attribution rests
    /// on. It is not in the SDK's headers, so it is looked up by name; its absence is said,
    /// never guessed past. [LAW:no-silent-failure]
    public static func current() throws(GrantReadingFailure) -> Holder {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            throw GrantReadingFailure("this macOS has no responsibility_get_pid_responsible_for_pid, so the app holding the grants cannot be named")
        }
        let pid = unsafeBitCast(symbol, to: Responsible.self)(getpid())
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            throw GrantReadingFailure("the responsible process \(pid) has no path to read: \(String(cString: strerror(errno)))")
        }
        return Holder(executable: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
}
