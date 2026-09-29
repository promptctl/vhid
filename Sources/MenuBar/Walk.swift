import Doctor
import Foundation

/// The set-up walk: doctor's unmet rows, one page at a time, each explained before macOS is
/// asked for anything.
///
/// [LAW:one-source-of-truth] A view of `Readiness` and nothing more. Which steps there are,
/// and whether each is done, is read off doctor's list every time; the walk remembers only
/// what the list cannot know - which rows the person set aside, and which were already
/// asked in this walk.
///
/// Taken from low-talker's guided setup, without its microphone, input-method and hotkey
/// rows.
public struct Walk: Sendable, Hashable {
    /// What the menu item and the window call it.
    public static let title = "Set Up vhid…"

    /// Rows the person set aside in this walk. Kept only while the walk is open: a skipped
    /// row is offered again the next time it opens.
    public private(set) var skipped: Set<Requirement.Row> = []
    /// Rows whose request went through in this walk. macOS shows most of these dialogs once,
    /// so a second press of the same button would do nothing: once asked, a row still unmet
    /// offers System Settings instead, and says why.
    public private(set) var asked: Set<Requirement.Row> = []

    public init() {}

    /// What the window shows for a reading.
    public enum Page: Sendable, Hashable {
        /// The first unmet row not set aside, and how many unmet rows are left.
        case step(Requirement, left: Int)
        /// Nothing left that is not set aside: every row, met ones with their readings and
        /// set-aside ones with what skipping them costs.
        case summary(met: [Requirement], skipped: [Requirement])
    }

    /// [LAW:dataflow-not-control-flow] The page is chosen by what the walk reads off the
    /// list, never by a mode the window keeps.
    public func page(_ readiness: Readiness) -> Page {
        let unmet = readiness.requirements.filter { !$0.met }
        guard let current = unmet.first(where: { !skipped.contains($0.row) }) else {
            return .summary(met: readiness.requirements.filter(\.met), skipped: unmet)
        }
        return .step(current, left: unmet.count)
    }

    /// The button that makes macOS ask, when this page has one: the row's request, not yet
    /// made in this walk.
    public func ask(_ requirement: Requirement) -> Requirement.Ask? {
        asked.contains(requirement.row) ? nil : requirement.ask
    }

    /// Whether the page says macOS asks only once, and points at System Settings instead.
    public func askedAlready(_ requirement: Requirement) -> Bool {
        requirement.ask != nil && asked.contains(requirement.row)
    }

    public mutating func skip(_ row: Requirement.Row) { skipped.insert(row) }

    /// Brings a skipped row back, which is how the summary resumes the walk at it.
    public mutating func revisit(_ row: Requirement.Row) { skipped.remove(row) }

    /// A request that went through: macOS showed its dialog. One that failed showed none,
    /// so it is not recorded, and its button stays beside the reason.
    public mutating func asked(_ row: Requirement.Row) { asked.insert(row) }
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

    /// Where this row is switched by hand, when System Settings has a pane for it.
    var settingsPane: URL? {
        switch self {
        case .driverExtension: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        case .launchdJob, .daemon, .signature, .devices, .keyboardSetupAssistant: nil
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

    /// What the page says while the request waits: the Manager's `activate` returns only
    /// once the person answers macOS, so the wait is named before it starts.
    var waiting: String {
        switch self {
        case .activateDriver:
            "Waiting for you to answer macOS about \"Karabiner-VirtualHIDDevice-Manager\", then to turn the driver on in System Settings."
        }
    }
}
