/// Something that can say what text is on screen and where.
///
/// Two readers answer this: one walks the accessibility tree, one recognises pixels. They
/// are two behaviors and so two types, and they conform to one protocol so a caller holds
/// a reader without knowing or caring which. [LAW:composability] That is also what makes
/// a merged reader possible - one that asks both and reconciles the answers is a third
/// conformance, not a branch at every call site. [LAW:dataflow-not-control-flow]
///
/// Main-actor because reading the screen is a question about the user's session.
@MainActor
public protocol Reader: Sendable {
    /// What this reader is, for a finding to carry and a caller to read back.
    var source: SourceKind { get }

    /// Everything the reader saw in the query's region, before any of it is judged
    /// against the query, or a throw when it could not look at all. `read` judges it.
    ///
    /// Unjudged so a merged reader reconciles what two readers saw rather than what
    /// survived each one's match and limit, and judges the union once. [LAW:single-enforcer]
    ///
    /// A region with nothing in it is an answer and comes back as one, carrying its
    /// scope. Throwing is for a reader that could not see - no grant, no such display, a
    /// capture that wrote nothing - because those are facts about the tool and not about
    /// the screen, and a caller told "nothing matched" would take them for an absence.
    /// [LAW:no-silent-failure]
    func look(_ query: Query) async throws -> Candidates

    /// The judged rows with each box this reader can check cut to where a click presses
    /// what the row names, and every other row as it was.
    ///
    /// After judging, so the checks - calls into other processes - are spent on the rows a
    /// caller is shown and not on every element a walk read. A reader whose boxes are
    /// already where a click lands answers the reading it was given. Rows the checks have
    /// not reached by `deadline` stand as placed, counted as over time.
    func pressing(_ reading: Reading, until deadline: ContinuousClock.Instant) async throws -> Reading
}

/// How long checking a reading's boxes may take, on top of the read. A page's button costs a
/// few dozen calls at 10-35 ms each; an app too busy to answer holds each for the messaging
/// timeout, and the rows the time does not reach are counted unchecked as over time.
public let boxChecking = Duration.seconds(2)

public extension Reader {
    /// The query's rows: what the reader saw, judged by the one rule every reader shares,
    /// held with this reader to check their boxes.
    func judged(_ query: Query) async throws -> Judged {
        Judged(Reading.judging(try await look(query), query: query)) { try await self.pressing($0, until: $1) }
    }
}

/// A judged reading whose boxes are not yet checked, and the check: the boxes cost calls
/// into other processes and only the rows a caller is shown need them, so a wait polls the
/// reading and checks the boxes of the one it ends on. [LAW:types-are-the-program] Its own
/// type, so a reading is printed only once pressed.
public struct Judged: Sendable {
    public typealias Press = @Sendable (Reading, ContinuousClock.Instant) async throws -> Reading

    public let reading: Reading
    private let press: Press

    public init(_ reading: Reading, pressedBy press: @escaping Press) {
        self.reading = reading
        self.press = press
    }

    /// The reading, each box checked by the reader that placed it by `deadline`.
    public func pressed(until deadline: ContinuousClock.Instant = .now + boxChecking) async throws -> Reading {
        try await press(reading, deadline)
    }
}

/// What checking one row's box against where a click lands found.
public enum Pressed: Sendable, Hashable {
    /// The box stands: a click anywhere in it presses the element, as far as was checked,
    /// or the row is another reader's to check.
    case kept
    /// Part of the box presses something else; this is the part that presses the element.
    case narrowed(ScreenRect)
    /// The box could not be checked, and stands as the reader placed it.
    case unchecked(Unchecked)
}

/// Why a row's box could not be checked.
public enum Unchecked: String, Sendable, Hashable, CaseIterable {
    /// The hit test, or a read of what it hit, did not answer.
    case unanswered
    /// A click at the row's own point lands on something other than the element it names.
    case elsewhere
    /// The time for checking the reading's boxes ran out first.
    case overTime = "over_time"
}

/// One row's check, and the calls into the app - hit tests and reads - it made.
public struct Checked: Sendable, Hashable {
    public let pressed: Pressed
    public let calls: Int

    public init(_ pressed: Pressed, calls: Int) {
        self.pressed = pressed
        self.calls = calls
    }
}

/// Which kind of reader, without the per-finding payload `Source` carries.
public enum SourceKind: String, Sendable, Hashable, CaseIterable {
    case tree
    case pixels
    /// Both, reconciled.
    case merged
}

public extension Source {
    var kind: SourceKind {
        switch self {
        case .tree: .tree
        case .pixels: .pixels
        case .merged: .merged
        }
    }
}
