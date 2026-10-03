import AppKit
import SystemConfiguration
import ArgumentParser

/// Where keys may go: wherever the keyboard is pointed, or only into the app named.
///
/// An agent looks, then acts a moment later, and in between a dialog, a notification or
/// another app can come forward. Aimed into an app, a verb asks which app is in front
/// after everything it will send has been read, and sends nothing when it is another.
/// It asks once, before the first key: a window that comes forward while the keys are
/// going down still gets the rest of them.
enum Aim: Sendable, Equatable {
    case anywhere
    /// An application's name, as `eyes windows` prints the frontmost application.
    case into(String)

    /// Throws `NotInFront`, before a key has gone down, unless `front` is the app aimed at.
    /// `front` is read only when there is an app to compare it with, so keys aimed
    /// `anywhere` cost no question of the daemon or of macOS.
    func admit(_ front: () async throws -> FrontApp?) async throws {
        guard case .into(let app) = self else { return }
        let inFront = try await front()
        // Exact: a name taken from eyes is spelled as macOS spells it, and a looser match
        // would let "Notes" admit Sticky Notes. [LAW:parse-dont-validate]
        guard inFront?.name == app else { throw NotInFront(aimed: app, front: inFront) }
    }

    /// What a verb adds to its report: where the keys were checked to go, or nothing.
    var said: String {
        switch self {
        case .anywhere: ""
        case .into(let app): " into \(app)"
        }
    }

    /// An app named on the command line or in a tool's arguments; an empty name names
    /// nothing that could ever be in front, so it is refused rather than never matched.
    init?(named app: String?) {
        switch app {
        case nil: self = .anywhere
        case let app? where app.isEmpty: return nil
        case let app?: self = .into(app)
        }
    }
}

/// The application in front: where keys usually go.
struct FrontApp: Sendable, Equatable, CustomStringConvertible {
    let pid: Int32
    let name: String?

    var description: String { "\(name ?? "(unnamed)") (pid \(pid))" }

    /// Asked of macOS on every call, never kept: what was in front a moment ago is the
    /// question this exists to stop answering. [LAW:no-ambient-temporal-coupling]
    ///
    /// The same reading as eyes' `Frontmost` (eyes/Sources/Command/Windows.swift), the
    /// name on its scope line, so a name copied from there matches. A window's owner
    /// column is the window server's name for the app, which usually but not always reads
    /// the same.
    ///
    /// NSWorkspace answers for this user's session, and the keys go to the session in
    /// front. So the console's user is asked first, and when it is another, or the login
    /// window's, the answer here would be about a session the keys do not reach: that is
    /// refused rather than read. [LAW:no-silent-failure]
    static let inFront: @Sendable () async throws -> FrontApp? = {
        var console: uid_t = 0
        let user = SCDynamicStoreCopyConsoleUser(nil, &console, nil) as String?
        try AnotherSessionInFront.check(user: user, console: console, mine: getuid())
        return await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map { FrontApp(pid: $0.processIdentifier, name: $0.localizedName) }
        }
    }
}

/// Keys aimed into an app, when the session in front is not this user's. Nothing was sent.
struct AnotherSessionInFront: Error, Equatable, CustomStringConvertible {
    let user: String?

    /// Throws unless the console's session is `mine`: a user's, not the login window's.
    /// [LAW:effects-at-boundaries] The reads are the caller's; this is only the rule.
    static func check(user: String?, console: uid_t, mine: uid_t) throws {
        guard let user, user != "loginwindow", console == mine else { throw AnotherSessionInFront(user: user) }
    }

    var description: String {
        let front = user.map { $0 == "loginwindow" ? "the login window is" : "\($0)'s session is" } ?? "no session is"
        return "\(front) in front, not this user's, so which app is in front cannot be read here and nothing was sent"
    }
}

/// Keys aimed into one app, when another was in front. Nothing was sent.
struct NotInFront: Error, Equatable, CustomStringConvertible {
    let aimed: String
    let front: FrontApp?

    var description: String {
        "\(aimed) is not in front, so nothing was sent: " + (front.map { "\($0) is" } ?? "no application is")
    }
}

/// `--into`, taken by `type` and `press`. [LAW:one-source-of-truth]
struct AimOption: ParsableArguments {
    @Option(name: .customLong("into"), help: Help.sentence(Help.into))
    var app: String?

    func aim() throws -> Aim {
        guard let aim = Aim(named: app) else { throw ValidationError("--into needs an application's name, and it is empty") }
        return aim
    }

    init() {}
}
