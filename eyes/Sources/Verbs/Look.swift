import AppKit
import ArgumentParser
import CoreGraphics
import DisplayReading
import ScreenSpace
import Seeing
import Grants
import Pixels
import Telemetry
import Tree

/// How a caller spells an argument's name in a refusal: `--limit` on the command line,
/// `limit` to an MCP client.
public enum Spelling: Sendable {
    case flag, argument

    func callAsFunction(_ name: String) -> String { self == .flag ? "--\(name)" : name }
}

/// What each argument of a look means, said once as a phrase: a tool's schema shows it as it
/// is, a refusal quotes it after "and it is", and the command line shows it as a sentence.
/// [LAW:one-source-of-truth]
public enum LookHelp {
    public static let text = "the text to find: any run that contains it matches, whatever its case"
    public static let exact = "whether to match only a run that is exactly the text"
    public static let edits = "how many single-character edits off the text a run may be and still match, for recogniser slips"
    public static let limit = "the most rows to answer with; defaults to \(Limit.default.count)"
    public static let display = "a display to read whole, every app on it, by its window-server id, which the display list gives and every scope line names."
        + " With no display, window, rect, page or app named, what is in front is read: the frontmost app's windows and what is stacked in front of them,"
        + " or the app of the frontmost window behind when the frontmost app has no window open or is the agent's own,"
        + " such as the terminal running it"
    public static let window = "a window to read the bounds of, by the id the window list gives"
    public static let rect = "a rectangle to read: x,y,width,height in the points vhid clicks, the form every rectangle eyes prints is in: a row's box, a window's or display's bounds, a scope line's region"
    public static let page = "a window whose web page to read, by the id the window list gives: the page alone,"
        + " not the browser's toolbar and bookmarks around it. Needs Accessibility, which finds the page"
    public static let app = "an app to read, its windows and what is stacked in front of them, named exactly as the window list names the frontmost app, e.g. Safari"
    public static let near = "text to order the matches by closeness to, nearest first: the Remove in Beta's row before the others."
        + " With nothing on screen containing it, no match is answered:"
        + " which one was meant is unknown, and a wait settles neither present nor absent"
    public static let until = "present or absent: read again until the text is, then answer once with the last reading."
        + " Absent counts only a region read whole, twice running"
    public static let timeout = "with until, the most seconds to wait: at most \(Int(Wait.longest)). A wait that runs out answers"
        + " with its last reading and says it timed out. Defaults to \(Int(Wait.defaultSeconds))"
    public static let role = "an accessibility role every row must be, as rows print it: AXButton for buttons, AXLink for links."
        + " A role is the tree's, so text the pixels alone saw is set aside as role unknown, and the read is not whole"
    public static let source = "which reader looks: tree (the accessibility tree: exact text and roles),"
        + " pixels (recognised text, anything drawn), or merged (both, each thing reported once;"
        + " answers with either grant, naming a reader that could not look). Defaults to merged. " + needs
    /// Which grant each reader needs, built from the one mapping. [LAW:one-source-of-truth]
    public static let needs = Grant.allCases.sorted { $0.reader.rawValue > $1.reader.rawValue }
        .map { "the \($0.reader.rawValue) reader needs \($0.name)" }.joined(separator: " and ")
}

extension ArgumentHelp {
    /// A phrase as the command line shows it: capitalised, with a full stop. The one
    /// rendering, for both halves' verbs. [LAW:one-source-of-truth]
    public static func sentence(_ phrase: String) -> ArgumentHelp {
        ArgumentHelp(phrase.prefix(1).uppercased() + phrase.dropFirst() + ".")
    }
}

/// Which reader a verb or tool reads with: every kind a reader can be. [LAW:one-source-of-truth]
extension SourceKind: ExpressibleByArgument {
    /// The reader of this kind. Merged puts the tree first, so where both saw a thing its
    /// exact frame and role are the ones kept.
    @MainActor var reader: any Reader {
        switch self {
        case .tree: TreeReader(granted: Self.granted)
        case .pixels: PixelReader(granted: Self.granted, hit: TreeReader.hit)
        case .merged: MergedReader(TreeReader(granted: Self.granted), PixelReader(granted: Self.granted, hit: TreeReader.hit), locate: { try $0.bounds(on: $1) })
        }
    }

    /// Every reader's gate: a fresh reading, the one `eyes grants` and `vhid doctor` print, so
    /// a reader and the grants it is said to have cannot disagree - and a grant switched on
    /// under a running `vhid mcp` is seen by the first read that takes a reading after it;
    /// one taken under a second before is shared. [LAW:one-source-of-truth]
    static let granted: Gate = { try await readings.holds($0) }
    /// [LAW:no-shared-mutable-globals] The process's one grant reading in flight, shared
    /// by every gate that asks while it is taken; private, so `granted` is its one user.
    private static let readings = SharedReading(take: GrantsVerb.reading)

    /// The scope line's name for who looked.
    var looked: String {
        switch self {
        case .tree: "by the tree"
        case .pixels: "by pixels"
        case .merged: "by tree and pixels, merged"
        }
    }
}

/// Where `find` and `read` look, shared so the two verbs cannot disagree about it.
public struct Where: ParsableArguments {
    @Option(help: .sentence(LookHelp.display))
    public var display: UInt32?

    @Option(help: .sentence(LookHelp.window))
    public var window: UInt32?

    /// Takes the next argument whatever it starts with: a box on a display left of or
    /// above the main one starts with a minus, which would otherwise read as a flag.
    @Option(parsing: .unconditional, help: .sentence(LookHelp.rect))
    public var rect: String?

    @Option(help: .sentence(LookHelp.page))
    public var page: UInt32?

    @Option(help: .sentence(LookHelp.app))
    public var app: String?

    public init() {}

    public func validate() throws {
        _ = try Self.place(display: display, window: window, page: page, rect: rect, app: app, as: .flag)
    }

    /// The place these flags name.
    var named: Place {
        get throws { try Self.place(display: display, window: window, page: page, rect: rect, app: app, as: .flag) }
    }

    /// The one place a region is spelled from its five arguments, for the verbs and the
    /// MCP tool alike, each naming an argument the way its caller spells it.
    /// [LAW:single-enforcer]
    ///
    /// Naming no place reads what is in front: what a caller that did not say where means is
    /// the app a person sees in front, not every window on the desk. The scope line names the app.
    static func place(display: UInt32?, window: UInt32?, page: UInt32?, rect: String?, app: String?, as s: Spelling) throws -> Place {
        let named = [("display", display != nil), ("window", window != nil), ("page", page != nil), ("rect", rect != nil), ("app", app != nil)]
        guard named.filter(\.1).count <= 1 else {
            throw ValidationError("give at most one of " + named.map { s($0.0) }.joined(separator: ", "))
        }
        if let app, app.isEmpty { throw ValidationError("\(s("app")) is empty, which names no app") }
        return try page.map(Place.page)
            ?? rect.map { .region(.rect(try parsedRect($0, as: s))) }
            ?? window.map { .region(.window($0)) }
            ?? display.map { .region(.display($0)) }
            ?? app.map(Place.app)
            ?? .front
    }

    /// Where a verb was told to look: a region as spelled, a window's web page, whose frame
    /// only the tree can find, what is in front, or an app by name - each found when the look
    /// is made, not when the arguments are parsed.
    enum Place: Sendable {
        case region(Region)
        case page(UInt32)
        case front
        case app(String)

        /// What a window's tree says of its pages: the tree in the process, a fake in a test.
        typealias Pages = @Sendable @MainActor (UInt32) async throws -> Paged
        static let tree: Pages = { try await TreeReader(granted: SourceKind.granted).pages(in: $0) }

        /// The screen now: AppKit, the window server and the responsibility call in the
        /// process, a fake in a test.
        typealias Desks = @Sendable @MainActor () async throws -> Desk
        static let live: Desks = { try await Desk.now() }

        /// The display layout now: the window server in the process, a fake in a test.
        typealias Layouts = @Sendable @MainActor () async throws -> DisplayLayout
        static let layouts: Layouts = { try DisplayReading.layout() }

        /// The region, on the layout it was found on: the desk's, when the app in front was
        /// chosen on it, so the choice and the read are of one moment, and one read for it
        /// otherwise. [LAW:one-source-of-truth]
        @MainActor func located(on screen: Screen) async throws -> Located {
            switch self {
            case .region(let region): Located(region: region, layout: try await screen.layouts())
            case .page(let id): Located(region: try await Self.page(id, pages: screen.pages), layout: try await screen.layouts())
            case .front: try await Self.front(screen.desk, "in_front") { try Front.choose(on: $0) }
            case .app(let name): try await Self.front(screen.desk, "named") { try Front.named(name, on: $0) }
            }
        }

        /// [LAW:nothing-unseen] Choosing the app is a decision of its own, before any look
        /// starts: which app, how it was chosen, on which display, and which app it passed over.
        @MainActor private static func front(_ desks: Desks, _ chosen: String, by rule: (Desk) throws -> Front) async throws -> Located {
            try await Telemetry.unit("front") {
                Telemetry.note(.chosen, .string(chosen))
                let desk = try await desks()
                let front = try rule(desk)
                Telemetry.note(.frontApp, front.app.name.map(JSON.string))
                Telemetry.note(.frontPid, .int(Int(front.app.pid)))
                Telemetry.note(.display, .int(Int(front.display)))
                Telemetry.note(.passedOver, front.passedOver.map { .string($0.said) })
                // How many processes were matched as the agent's own app: zero means none
                // could be passed over or kept out, whatever is in front.
                Telemetry.count(.ownPids, front.own.pids.count)
                return Located(region: .front(front), layout: desk.layout)
            }
        }

        /// [LAW:nothing-unseen] Finding a page is a walk of its own, before any look starts,
        /// so it is a unit of its own: how much it read, how many pages it saw, and why it
        /// stopped short when it did.
        @MainActor private static func page(_ id: UInt32, pages: Pages) async throws -> Region {
            try await Telemetry.unit("page") {
                let paged = try await pages(id)
                Telemetry.count(.examined, paged.examined)
                Telemetry.count(.pages, paged.pages.count)
                Telemetry.note(.reach, .string((paged.stop?.reach ?? .whole).kind))
                return .page(window: id, frame: try paged.page(in: id))
            }
        }
    }

    /// A place as a look found it: the region, and the layout its first read is on.
    struct Located: Sendable {
        let region: Region
        let layout: DisplayLayout
    }

    /// How many rows, for both verbs and both tools.
    static func limit(_ count: Int, as s: Spelling) throws -> Limit {
        guard let limit = Limit(count) else { throw ValidationError("\(s("limit")) must be at least 1") }
        return limit
    }

    /// A box with area: one with none has nothing in it to read.
    private static func parsedRect(_ spelled: String, as s: Spelling) throws -> ScreenRect {
        let rect: ScreenRect
        do throws(Misspelled) { rect = try ScreenRect(spelled: spelled) } catch { throw ValidationError("\(s("rect")): \(error)") }
        guard !rect.isEmpty else { throw ValidationError("\(s("rect")) wants a box with area, \(ScreenRect.spelling) - got \(spelled)") }
        return rect
    }
}

/// What `find` and `read` print. Pure, so the sentences a caller trusts are tested.
/// [LAW:effects-at-boundaries]
enum Report {
    static func lines(_ reading: Reading, query: Query, source: SourceKind) -> [String] {
        [scope(reading, query: query, source: source)] + rows(reading.outcome)
    }

    /// Names where it looked, how much it read, and every narrowing, before any row.
    /// [LAW:no-silent-failure]
    static func scope(_ reading: Reading, query: Query, source: SourceKind) -> String {
        let s = reading.scope
        let role = query.role.map { " as \($0.rawValue)" } ?? ""
        let asked = query.match.map { match in wanted(match) + role + (query.near.map { " near \(wanted($0))" } ?? "") }
        let head: String = switch reading.outcome {
        case .matched(let m):
            asked.map { "\(m.count) matched \($0)" } ?? "\(m.count) run\(m.count == 1 ? "" : "s")\(role)"
        case .nearest:
            asked.map { "\($0) not found" } ?? "no text\(role)"
        case .unanchored:
            // The near misses that follow are the anchor's, so the anchor is what is named
            // not found. [LAW:no-silent-failure]
            "\(query.near.map(wanted) ?? "") not found to place \(query.match.map(wanted) ?? "the text")\(role) near"
        }
        let clauses: [String?] = [
            // A partial read says so in the words a caller acts on, not only in the last clause:
            // what it matched or missed may be the wrong thing, or not all there is.
            "\(head) in \(s.reach.readWhole ? "" : "the part read of ")\(place(query.region)) \(s.region) \(looked(source, s.reach))",
            "\(s.examined) run\(s.examined == 1 ? "" : "s") read",
            s.excluded.isEmpty ? nil : s.excluded.map { "\($0.count) \($0.reason.rawValue)" }.joined(separator: ", "),
            boxes(s.boxes),
            reach(s.reach),
            reading.outcome.misses.isEmpty ? nil : "nearest follow",
        ]
        return clauses.compactMap { $0 }.joined(separator: "; ") + ". Each row's point is where a click presses it, inside its box, the part of it a display shows, x,y,width,height, in vhid click coordinates."
    }

    /// What checking the boxes did, when it did anything: a box cut is a row whose frame the
    /// app claimed wider than a click presses it, and a box unchecked stands as claimed, with
    /// why.
    static func boxes(_ b: Boxes) -> String? {
        let unchecked = b.uncheckedCount
        let why = Unchecked.allCases.compactMap { reason in b.unchecked[reason, default: 0] > 0 ? "\(b.unchecked[reason, default: 0]) \(said(reason))" : nil }
        let clauses = [b.narrowed > 0 ? "\(b.narrowed) box\(b.narrowed == 1 ? "" : "es") cut to where a click presses it" : nil,
                    unchecked > 0 ? "\(unchecked) box\(unchecked == 1 ? "" : "es") unchecked (\(why.joined(separator: ", ")))" : nil].compactMap { $0 }
        return clauses.isEmpty ? nil : clauses.joined(separator: ", ")
    }

    private static func said(_ why: Unchecked) -> String {
        switch why {
        case .unanswered: "unanswered"
        case .elsewhere: "its point on something else"
        case .unshown: "its pressed part on no display"
        case .overTime: "out of time"
        }
    }

    /// One run per row: the point a click presses it at, the part of it a display shows, the text,
    /// and what it is - the role the tree gave it, or `pixels` for text only the pixels
    /// reader saw, which has none - then what else its element says in words, each after the
    /// attribute that says it: a "+" button's `description Add`. The nearest rows add, before those,
    /// how many edits off they were. Every text is spelled on one line.
    static func rows(_ outcome: Outcome) -> [String] {
        switch outcome {
        case .matched(let m): m.all.map { row($0) }
        case .nearest(let near), .unanchored(let near): near.map { row($0.found, then: ["\($0.distance) off"]) }
        }
    }

    /// The columns every row has in the same place - `then`, a near miss's distance, among
    /// them - before the element's other words, however many it says.
    private static func row(_ found: Found, then: [String] = []) -> String {
        (["\(found.press)", "\(found.frame)", spelled(found.text.value), found.source.role?.rawValue ?? "pixels"]
            + then + found.source.also.map { "\($0.attribute.rawValue) \(spelled($0.text.value))" }).joined(separator: "\t")
    }

    /// The most of one text a row prints: a control's name whole, never a terminal's or a
    /// document's whole contents, which is a text area's value.
    static let longest = 120

    /// A text on one line - a row is one element - its whitespace runs, newlines and tabs
    /// among them, as one space, and cut past `longest` saying how long it was, so a cut text
    /// is never taken for a whole one. [LAW:no-silent-failure] Stops reading at the cut: a text
    /// area's value is a whole document.
    static func spelled(_ text: String) -> String {
        var line = "", length = 0, gap = false
        for character in text {
            if character.isWhitespace { gap = length > 0; continue }
            if gap { line.append(" "); length += 1; gap = false }
            guard length < longest else { return "\(line.prefix(longest))... (\(text.count) characters)" }
            line.append(character)
            length += 1
        }
        return line
    }

    private static func wanted(_ match: Match) -> String {
        switch match {
        case .contains(let s): "\"\(s)\""
        case .exact(let s): "exactly \"\(s)\""
        case .within(let e, let s): "\"\(s)\" within \(e.count) edit\(e.count == 1 ? "" : "s")"
        }
    }

    private static func place(_ region: Region) -> String {
        switch region {
        case .display(let id): "display \(id)"
        // Its bounds, as pixels: a window partly under another reads what is on top.
        case .window(let id): "what is on top over window \(id)"
        case .rect: "rect"
        case .page(let id, _): "the page in window \(id)"
        case .front(let f):
            "\(f.app) and what is in front of it\(f.passedOver.map { ", passing over \($0.clause)," } ?? "") on display \(f.display)"
        }
    }

    /// Who looked, as it happened rather than as asked: a merge one of whose readers was
    /// blind was read by the other alone.
    private static func looked(_ source: SourceKind, _ reach: Reach) -> String {
        guard case .stopped(.merged(let a, let b)) = reach, a.isBlind != b.isBlind else { return source.looked }
        return "by \((a.isBlind ? b : a).kind.rawValue) alone"
    }

    private static func reach(_ reach: Reach) -> String {
        switch reach {
        case .whole: "whole region read"
        case .stopped(.resultLimit(let l)): "stopped at the limit of \(l.count)"
        case .stopped(.elementLimit(let l)): "stopped at \(l.count) elements"
        case .stopped(.timeBudget(let d)): "stopped after \(d)"
        case .stopped(.unread): "parts left unread"
        case .stopped(.merged(let a, let b)): "\(part(a)), \(part(b))"
        }
    }

    private static func part(_ part: Part) -> String {
        switch part {
        case .read(let kind, let r): "\(kind.rawValue) \(reach(r))"
        // One line whatever the error printed, since the scope is one line.
        case .blind(let kind, let why, _):
            "\(kind.rawValue) could not look (\(why.split(whereSeparator: \.isNewline).joined(separator: " ")))"
        }
    }

}

private extension Paged.Stop {
    /// Why a page search stopped short, as the reach a look reports, so a page's event and a
    /// look's spell it the one way. [LAW:one-source-of-truth]
    var reach: Reach {
        switch self {
        case .elementLimit(let l): .stopped(.elementLimit(l))
        case .timeBudget(let d): .stopped(.timeBudget(d))
        case .unread: .stopped(.unread)
        }
    }
}

private extension Reach {
    /// How far a look read, for its event. A merge that did not read whole names each
    /// reader's reach, `tree_blind+pixels_whole`, since merged is the default source and a
    /// missing grant and a time budget are different causes.
    var kind: String {
        switch self {
        case .whole: "whole"
        case .stopped(.resultLimit): "result_limit"
        case .stopped(.elementLimit): "element_limit"
        case .stopped(.timeBudget): "time_budget"
        case .stopped(.unread): "unread"
        case .stopped(.merged(let a, let b)): "\(a.reachKind)+\(b.reachKind)"
        }
    }
}

private extension Part {
    /// One reader's reach in a merge, for the look's event.
    var reachKind: String {
        switch self {
        case .read(let source, let reach): "\(source.rawValue)_\(reach.kind)"
        case .blind(let source, _, _): "\(source.rawValue)_blind"
        }
    }
}

private extension Region {
    /// Which kind of place was read, for the look's event.
    var kind: String {
        switch self {
        case .display: "display"
        case .window: "window"
        case .page: "page"
        case .rect: "rect"
        case .front: "front"
        }
    }
}

private extension Outcome {
    /// The near misses that follow the scope line: none when something matched.
    var misses: [Near] {
        switch self {
        case .matched: []
        case .nearest(let n), .unanchored(let n): n
        }
    }

    /// How a single look ended, for its event.
    var said: String {
        switch self {
        case .matched: "matched"
        case .nearest: "not_matched"
        case .unanchored: "unanchored"
        }
    }
}

extension Report {
    /// A query's reading as the text the verbs print and the MCP tools answer: one read, or
    /// with a wait, the read the wait ended on, its scope line led by how the wait went.
    /// [LAW:one-source-of-truth] The first read is on `layout`, the one the region was found
    /// on; each later read of a wait is on one `layouts` reads for it.
    static func text(
        _ query: Query, on layout: DisplayLayout, source: SourceKind, wait: Wait? = nil,
        layouts: () async throws -> DisplayLayout,
        reading read: @Sendable (SourceKind, Query, DisplayLayout) async throws -> Judged
    ) async throws -> String {
        // [LAW:nothing-unseen] One event per look, from the one path every verb and tool
        // reads through: which reader, what it read, and how it ended.
        try await Telemetry.unit("reading", result: { $0.result }) {
            Telemetry.note(.source, .string(source.rawValue))
            Telemetry.note(.region, .string(query.region.kind))
            Telemetry.note(.order, .string(query.near == nil ? "reading" : "near"))
            Telemetry.note(.role, query.role.map { JSON.string($0.rawValue) })
            // Tallied as each read starts, so a look that fails says how many it spent.
            Telemetry.count(.reads, 0)
            Telemetry.count(.boxMilliseconds, 0)
            // The boxes' checks timed apart from the read, wherever they run - after a read,
            // or at the end of a wait.
            func counted(_ query: Query, on layout: DisplayLayout) async throws -> Judged {
                Telemetry.tally(.reads)
                let judged = try await read(source, query, layout)
                return Judged(judged.reading) { _, deadline in
                    let start = ContinuousClock.now
                    defer { Telemetry.tally(.boxMilliseconds, by: Int((ContinuousClock.now - start) / .milliseconds(1))) }
                    return try await judged.pressed(until: deadline)
                }
            }
            guard let wait else {
                let reading = try await counted(query, on: layout).pressed()
                Self.count(reading, query)
                return (text: lines(reading, query: query, source: source).joined(separator: "\n"),
                        result: reading.outcome.said)
            }
            Telemetry.note(.until, .string(wait.until.rawValue))
            let waited = try await waiting(for: wait, on: query, on: layout, layouts: layouts, read: counted)
            Self.count(waited.reading, query)
            let said = lines(waited.reading, query: query, source: source)
            return (text: ([waitedClause(waited, wait) + said[0]] + said.dropFirst()).joined(separator: "\n"),
                    result: waited.settled ? "settled" : "timed_out")
        }.text
    }

    /// The counts of the reading a look ended on, zeros included.
    private static func count(_ reading: Reading, _ query: Query) {
        Telemetry.count(.examined, reading.scope.examined)
        Telemetry.count(.boxesNarrowed, reading.scope.boxes.narrowed)
        Telemetry.note(.boxesUnchecked, .object(Dictionary(uniqueKeysWithValues: reading.scope.boxes.unchecked.map { ($0.key.rawValue, JSON.int($0.value)) })))
        Telemetry.count(.boxCalls, reading.scope.boxes.calls)
        Telemetry.note(.excluded, .object(Dictionary(uniqueKeysWithValues: Exclusion.Reason.allCases.map { why in
            (why.rawValue, JSON.int(reading.scope.excluded.first { $0.reason == why }?.count ?? 0))
        })))
        // How many processes' windows a front look took in; every other region reads them all.
        if case .only(let pids) = reading.scope.owners { Telemetry.count(.owners, pids.count) }
        Telemetry.note(.reach, .string(reading.scope.reach.kind))
        switch reading.outcome {
        case .matched(let m):
            Telemetry.count(.matched, m.count)
            Telemetry.count(.nearest, 0)
            // Rows matched by another of their element's texts than the one they show.
            Telemetry.count(.matchedAlso, m.all.filter { if case .also = query.match.fit($0) { true } else { false } }.count)
        case .nearest(let n), .unanchored(let n):
            Telemetry.count(.matched, 0)
            Telemetry.count(.nearest, n.count)
            Telemetry.count(.matchedAlso, 0)
        }
    }

    /// How a wait went, ahead of the scope of the reading it ended on. A timeout is said
    /// as plainly as a success: it is an answer, not an error.
    static func waitedClause(_ waited: Waited, _ wait: Wait) -> String {
        let reads = "\(waited.reads) read\(waited.reads == 1 ? "" : "s") in \(seconds(waited.took))"
        return waited.settled
            ? "\(wait.until.rawValue) after \(reads): "
            : "timed out, not \(wait.until.rawValue) after \(reads): "
    }

    private static func seconds(_ d: Duration) -> String {
        let (s, atto) = d.components
        return String(format: "%.1fs", Double(s) + Double(atto) / 1e18)
    }
}

extension Until: ExpressibleByArgument {}

extension Front.Passed {
    /// The agent's own app: every process among `running` of the app responsible for this
    /// one, `holder`, matched by where it runs from, never by name - two apps can share one.
    /// The one place it is derived, for a front look and a hit alike. [LAW:one-source-of-truth]
    init(holder: Holder, among running: [NSRunningApplication]) {
        let path = { (url: URL?) in url?.resolvingSymlinksInPath().path }
        let holderPath = path(URL(fileURLWithPath: holder.path))
        let own = running.filter { path($0.bundleURL ?? $0.executableURL) == holderPath }
        self.init(pids: Set(own.map(\.processIdentifier)), name: holder.name)
    }
}

extension Front.PassedOver {
    /// The app passed over, as a scope line names it.
    var clause: String {
        switch self {
        case .own(let name): "\(name), the agent's own"
        case .windowless(let app): "\(app), which has no window open"
        }
    }

    /// The app passed over, as a record names it.
    var said: String {
        switch self {
        case .own(let name): name
        case .windowless(let app): "\(app)"
        }
    }
}

extension Desk {
    /// The screen now, frontmost first: an activation lands before the listing that reflects
    /// it. The running apps are read once, for the agent's own and every other alike, so no
    /// process can be among the running and missing from the agent's own.
    @MainActor
    static func now() async throws -> Desk {
        let holder = try await Holder.current()
        let frontmost = Front.App.now()
        let apps = NSWorkspace.shared.runningApplications
        let running = apps.map {
            Desk.Running(app: Front.App(pid: $0.processIdentifier, name: $0.localizedName), regular: $0.activationPolicy == .regular)
        }
        return Desk(frontmost: frontmost, own: Front.Passed(holder: holder, among: apps), running: running,
                    listing: try Geometry.onScreen(), layout: try DisplayReading.layout(), describe: Geometry.display)
    }
}
