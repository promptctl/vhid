import AppKit
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
    static let inFront: @Sendable () async -> FrontApp? = {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map { FrontApp(pid: $0.processIdentifier, name: $0.localizedName) }
        }
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
