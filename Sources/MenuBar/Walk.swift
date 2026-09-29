import Doctor
import Foundation

/// The set-up walk: doctor's unmet rows, one page at a time, each explained before macOS is
/// asked for anything.
///
/// [LAW:one-source-of-truth] A view of `Readiness` and nothing more. Which steps there are,
/// and whether each is done, is read off doctor's list every time; the walk remembers only
/// what the list cannot know: which rows the person set aside. Whether a request landed is
/// the list's to say - the driver reads installed-inactive until one does - so the button
/// that makes it stays for as long as that reading does.
///
/// Taken from low-talker's guided setup, without its microphone, input-method and hotkey
/// rows.
public struct Walk: Sendable, Hashable {
    /// What the menu item and the window call it.
    public static let title = "Set Up vhid…"

    /// Rows the person set aside in this walk. Kept only while the walk is open: a skipped
    /// row is offered again the next time it opens.
    public private(set) var skipped: Set<Requirement.Row> = []

    public init() {}

    /// What the window shows for a reading.
    public enum Page: Sendable, Hashable {
        /// The first unmet row not set aside and not waiting on another, and how many such
        /// rows are left, this one included.
        case step(Requirement, left: Int)
        /// No step left: every row, met ones with their readings, and unmet ones - set aside,
        /// or waiting on one that was - with what going without them costs.
        case summary(met: [Requirement], skipped: [Requirement])
    }

    /// [LAW:dataflow-not-control-flow] The page is chosen by what the walk reads off the
    /// list, never by a mode the window keeps.
    public func page(_ readiness: Readiness) -> Page {
        let unmet = readiness.requirements.filter { !$0.met }
        // A row waiting on an earlier one is no step of its own: the earlier row is.
        let ahead = unmet.filter { $0.waitsOn == nil && !skipped.contains($0.row) }
        guard let current = ahead.first else {
            return .summary(met: readiness.requirements.filter(\.met), skipped: unmet)
        }
        return .step(current, left: ahead.count)
    }

    public mutating func skip(_ row: Requirement.Row) { skipped.insert(row) }

    /// Brings a skipped row back, which is how the summary resumes the walk at it.
    public mutating func revisit(_ row: Requirement.Row) { skipped.remove(row) }

}

/// What the set-up window does, one event each, in the words its log records.
/// [LAW:nothing-unseen] A value, so what the log says is tested beside the walk.
public enum SetUpEvent: Sendable, Hashable, CustomStringConvertible {
    case page(Walk.Page)
    case skip(Requirement.Row)
    case revisit(Requirement.Row)
    case checkAgain(Requirement.Row)
    case openSettings(Requirement.Row)
    case askStarted(Requirement.Ask)
    case askFailed(Requirement.Ask, reason: String)
    /// The Manager a request started has exited, and what it said: its status proves
    /// nothing - it exits 0 whatever became of the request - but what it printed may.
    case askEnded(Requirement.Ask, status: Int32, said: String)

    public var description: String {
        switch self {
        case .page(.step(let requirement, let left)): "setup page: step \(requirement.name) (\(requirement.reads)), \(left) left"
        case .page(.summary(let met, let skipped)): "setup page: summary, \(met.count) met, \(skipped.count) set aside"
        case .skip(let row): "setup skip: \(row.rawValue)"
        case .revisit(let row): "setup revisit: \(row.rawValue)"
        case .checkAgain(let row): "setup check again: \(row.rawValue)"
        case .openSettings(let row): "setup open settings: \(row.rawValue)"
        case .askStarted(let ask): "setup ask: \(ask) started"
        case .askFailed(let ask, let reason): "setup ask: \(ask) could not start: \(reason)"
        case .askEnded(let ask, let status, let said): "setup ask: \(ask) ended \(status): \(said.isEmpty ? "said nothing" : said)"
        }
    }
}

/// Why a row is asked for, in the words a person reads before macOS asks them anything.
public struct Explanation: Sendable, Hashable {
    public let why: String
    public let ifSkipped: String
}

public extension Requirement.Row {
    /// [LAW:types-are-the-program] An exhaustive switch, so a row added to doctor cannot
    /// compile without the words a person needs before being asked for it.
    var explanation: Explanation {
        let noVerbs = "vhid's verbs are refused: nothing types or clicks."
        return switch self {
        case .driverExtension:
            Explanation(
                why: "vhid's keyboard and mouse are published through a driver extension, which macOS runs only once you approve it.",
                ifSkipped: noVerbs)
        case .launchdJob:
            Explanation(why: "launchd starts vhidd, the daemon that owns the keyboard and mouse, when a verb first calls it.", ifSkipped: noVerbs)
        case .daemon:
            Explanation(why: "vhidd holds the keyboard and mouse and sends every verb's keys and clicks.", ifSkipped: noVerbs)
        case .signature:
            Explanation(
                why: "vhidd serves only a vhid signed with its own certificate, so no other program types through it.",
                ifSkipped: "This copy of vhid is refused.")
        case .devices:
            Explanation(
                why: "One program drives the keyboard and mouse at a time.",
                ifSkipped: "Verbs from here are refused as busy until that program lets go.")
        case .keyboardSetupAssistant:
            Explanation(
                why: "macOS asks what kind of keyboard a new one is, in a window that takes the first keys typed. vhidd answers it for you.",
                ifSkipped: "The first keys vhid types may go to that window instead.")
        }
    }
}

public extension Requirement.Ask {
    /// The button's title. The ellipsis says a dialog follows.
    var title: String {
        switch self {
        case .activateDriver: "Activate Driver…"
        }
    }

}
