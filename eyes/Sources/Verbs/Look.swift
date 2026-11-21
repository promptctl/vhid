import AppKit
import ArgumentParser
import CoreGraphics
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

/// What each argument means, said once for a verb's help and an MCP tool's schema. Each is
/// a phrase, which a schema shows as it is and a refusal quotes after "and it is"; the
/// command line shows it as a sentence. [LAW:one-source-of-truth]
public enum Help {
    public static let text = "the text to look for, matching any run that contains it"
    public static let exact = "whether to match only a run that is exactly the text"
    public static let edits = "how many single-character edits off the text a run may be and still match, for recogniser slips"
    public static let display = "a whole display to read, every app on it, by its window-server id as the display list and every scope line name it;"
        + " with no app, display, window, rect or page, what is in front is read: the frontmost app's windows and what is stacked in front of them,"
        + " or the app behind when the frontmost is the one eyes answers to, such as the terminal running it"
    public static let app = "an app whose windows to read, and what is stacked in front of them, as a look with no place reads the app in front:"
        + " its name exactly as macOS spells it, the name the window list prints; its windows are read where they are, not brought forward"
    public static let window = "a window whose bounds to read, by the id the window list prints"
    public static let rect = "a rectangle to read, x,y,width,height in the points vhid clicks: the form every rectangle eyes prints is in,"
        + " a row's box, a window's or display's bounds, a scope line's region"
    public static let page = "a window whose web page to read, by the id the window list prints: the page alone,"
        + " not the browser's toolbar and bookmarks around it; needs Accessibility, which finds the page"
    public static let near = "text the matches are ordered beside, nearest a run containing it first:"
        + " the Remove in Beta's row before the others; with nothing on screen containing it, no match is answered,"
        + " since which one was meant is unknown, and a wait settles neither present nor absent"
    public static let until = "present or absent: read again until the text is, then answer once with the last reading;"
        + " absent counts only a region read whole, twice running"
    public static let timeout = "with until, the most seconds to wait, at most \(Int(Wait.longest)), and \(Int(Wait.defaultSeconds)) when left out;"
        + " a wait that runs out answers with its last reading and says it timed out"
    public static let role = "an accessibility role every row must have, as rows print it: AXButton for buttons, AXLink for links;"
        + " a role is the tree's, so text the pixels alone saw is set aside as role unknown, and the read is not whole"
    public static let source = "which reader looks: tree (the accessibility tree: exact text and roles),"
        + " pixels (recognised text, anything drawn), or merged (both, each thing reported once;"
        + " answers with either grant, naming a reader that could not look), merged when left out; " + needs
    public static let limit = "the most rows to answer with, \(Limit.default.count) when left out"
    public static let x = "the x of a point, in the screen points vhid clicks"
    public static let y = "the y of a point, in the same points"
    /// Which grant each reader needs, built from the one mapping. [LAW:one-source-of-truth]
    public static let needs = Grant.allCases.sorted { $0.reader.rawValue > $1.reader.rawValue }
        .map { "the \($0.reader.rawValue) reader needs \($0.name)" }.joined(separator: " and ")

    /// A phrase above as the command line shows it: capitalised, with a full stop.
    static func sentence(_ phrase: String) -> ArgumentHelp {
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
        case .merged: MergedReader(TreeReader(granted: Self.granted), PixelReader(granted: Self.granted, hit: TreeReader.hit), locate: { try $0.bounds() })
        }
    }

    /// Every reader's gate: a fresh reading, the one `eyes grants` prints, so a reader and
    /// the grants tool cannot disagree - and a grant switched on under a running `eyes mcp`
    /// is seen by its next read. [LAW:one-source-of-truth]
    static let granted: Gate = { try await readings.holds($0) }
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
struct Where: ParsableArguments {
    @Option(help: Help.sentence(Help.display))
    var display: UInt32?

    @Option(help: Help.sentence(Help.window))
    var window: UInt32?

    /// Takes the next argument whatever it starts with: a box on a display left of or
    /// above the main one starts with a minus, which would otherwise read as a flag.
    @Option(parsing: .unconditional, help: Help.sentence(Help.rect))
    var rect: String?

    @Option(help: Help.sentence(Help.page))
    var page: UInt32?

    @Option(help: Help.sentence(Help.app))
    var app: String?

    public func validate() throws {
        _ = try Self.place(app: app, display: display, window: window, page: page, rect: rect, as: .flag)
    }

    @MainActor var region: Region {
        get async throws { try await Self.place(app: app, display: display, window: window, page: page, rect: rect, as: .flag).region() }
    }

    /// The one place a region is spelled from its five arguments, for the verbs and the
    /// MCP tools alike, each naming an argument the way its caller spells it.
    /// [LAW:single-enforcer]
    ///
    /// Naming no place reads what is in front: what a caller that did not say where means is
    /// the app it is working in, not every window on the desk. Naming an app reads that app
    /// the same way. The scope line names the app.
    static func place(app: String?, display: UInt32?, window: UInt32?, page: UInt32?, rect: String?, as s: Spelling) throws -> Place {
        guard [app != nil, display != nil, window != nil, page != nil, rect != nil].filter({ $0 }).count <= 1 else {
            throw ValidationError("give at most one of \(s("app")), \(s("display")), \(s("window")), \(s("page")), \(s("rect"))")
        }
        guard app?.isEmpty != true else { throw ValidationError("\(s("app")) is empty, which names no app; leave it off to read the app in front") }
        return try page.map(Place.page)
            ?? rect.map { .region(.rect(try parsedRect($0, as: s))) }
            ?? window.map { .region(.window($0)) }
            ?? display.map { .region(.display($0)) }
            ?? .front(app)
    }

    /// Where a verb was told to look: a region as spelled, a window's web page, whose frame
    /// only the tree can find, or an app - the one in front, or the one named - each found
    /// when the look is made, not when the arguments are parsed.
    enum Place {
        case region(Region)
        case page(UInt32)
        case front(String?)

        /// What a window's tree says of its pages: the tree in the process, a fake in a test.
        typealias Pages = @Sendable @MainActor (UInt32) async throws -> Paged
        static let tree: Pages = { try await TreeReader(granted: SourceKind.granted).pages(in: $0) }

        /// The app a look reads now, the one in front or the one named: AppKit and the
        /// responsibility call in the process, a fake in a test.
        typealias Fronts = @Sendable @MainActor (String?) async throws -> Front
        static let live: Fronts = { name in
            let (own, listing, displays) = (try await Front.Passed.current(), try Geometry.onScreen(), Geometry.displays())
            return try name.map { try Front.now(named: $0, own: own, listing: listing, displays: displays) }
                ?? Front.now(own: own, listing: listing, displays: displays)
        }

        @MainActor func region(pages: Pages = tree, front: Fronts = live) async throws -> Region {
            switch self {
            case .region(let region): region
            case .page(let id): try await Self.page(id, pages: pages)
            case .front(let name): try await Self.front(name, front)
            }
        }

        /// [LAW:nothing-unseen] Choosing what is in front is a decision of its own, before any
        /// look starts: which app, on which display, and which app it passed over.
        @MainActor private static func front(_ name: String?, _ fronts: Fronts) async throws -> Region {
            try await Telemetry.unit("front") {
                Telemetry.note("named", name ?? "")
                let front = try await fronts(name)
                Telemetry.note("front_app", front.app.name ?? "")
                Telemetry.note("front_pid", String(front.app.pid))
                Telemetry.note("display", String(front.display))
                Telemetry.note("passed_over", front.passedOver ? front.own.name : "")
                // How many processes were matched as the app eyes answers to: zero means none
                // could be passed over or kept out, whatever is in front.
                Telemetry.count("own_pids", front.own.pids.count)
                return .front(front)
            }
        }

        /// [LAW:nothing-unseen] Finding a page is a walk of its own, before any look starts,
        /// so it is a unit of its own: how much it read, how many pages it saw, and why it
        /// stopped short when it did.
        @MainActor private static func page(_ id: UInt32, pages: Pages) async throws -> Region {
            try await Telemetry.unit("page") {
                let paged = try await pages(id)
                Telemetry.count("examined", paged.examined)
                Telemetry.count("pages", paged.pages.count)
                Telemetry.note("reach", (paged.stop?.reach ?? .whole).kind)
                return .page(window: id, frame: try paged.page(in: id))
            }
        }
    }

    /// How many rows, for both verbs and both tools.
    static func limit(_ count: Int, as s: Spelling) throws -> Limit {
        guard let limit = Limit(count) else { throw ValidationError("\(s("limit")) must be at least 1") }
        return limit
    }

    private static func parsedRect(_ spelled: String, as s: Spelling) throws -> ScreenRect {
        guard let rect = ScreenRect(spelled: spelled) else { throw ValidationError("\(s("rect")) wants \(ScreenRect.spelling) - got \(spelled)") }
        return rect
    }
}

/// What `find` and `read` print. Pure, so the sentences a caller trusts are tested.
/// [LAW:effects-at-boundaries]
enum Report {
    /// `grantNote` follows each missing grant named: where the grant is held, when that is
    /// not the process printing - an MCP server's host app.
    static func lines(_ reading: Reading, query: Query, source: SourceKind, grantNote: String = "") -> [String] {
        [scope(reading, query: query, source: source, grantNote: grantNote)] + rows(reading.outcome)
    }

    /// Names where it looked, how much it read, and every narrowing, before any row.
    /// [LAW:no-silent-failure]
    static func scope(_ reading: Reading, query: Query, source: SourceKind, grantNote: String = "") -> String {
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
            reach(s.reach, grantNote),
            reading.outcome.misses.isEmpty ? nil : "nearest follow",
        ]
        return clauses.compactMap { $0 }.joined(separator: "; ") + ". Each row's point is its centre and its box holds it, x,y,width,height, in vhid click coordinates."
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
        case .overTime: "out of time"
        }
    }

    /// One run per row: the centre a click lands on, the box around the run, the text,
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
        let at = clickPoint(found.frame.centre)
        return (["\(Int(at.x)),\(Int(at.y))", "\(box(found.frame, holding: at))", spelled(found.text.value), found.source.role?.rawValue ?? "pixels"]
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

    /// The whole point a click is sent to: the frame's centre, rounded.
    private static func clickPoint(_ p: ScreenPoint) -> CGPoint { CGPoint(x: p.x.rounded(), y: p.y.rounded()) }

    /// The frame grown to cover the cell of the point printed beside it. The rounded point
    /// can fall past the frame's right or bottom edge, which half-open containment counts as
    /// outside, so the point is covered by construction rather than by luck of the rounding.
    private static func box(_ frame: ScreenRect, holding at: CGPoint) -> ScreenRect {
        ScreenRect(frame.cgRect.union(CGRect(origin: at, size: CGSize(width: 1, height: 1))))
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
            "\(f.app) and what is in front of it\(f.passedOver ? ", passing over \(f.own.name), which eyes answers to," : "") on display \(f.display)"
        }
    }

    /// Who looked, as it happened rather than as asked: a merge one of whose readers was
    /// blind was read by the other alone.
    private static func looked(_ source: SourceKind, _ reach: Reach) -> String {
        guard case .stopped(.merged(let a, let b)) = reach, a.isBlind != b.isBlind else { return source.looked }
        return "by \((a.isBlind ? b : a).kind.rawValue) alone"
    }

    private static func reach(_ reach: Reach, _ grantNote: String = "") -> String {
        switch reach {
        case .whole: "whole region read"
        case .stopped(.resultLimit(let l)): "stopped at the limit of \(l.count)"
        case .stopped(.elementLimit(let l)): "stopped at \(l.count) elements"
        case .stopped(.timeBudget(let d)): "stopped after \(d)"
        case .stopped(.unread): "parts left unread"
        case .stopped(.merged(let a, let b)): "\(part(a, grantNote)), \(part(b, grantNote))"
        }
    }

    private static func part(_ part: Part, _ grantNote: String) -> String {
        switch part {
        case .read(let kind, let r): "\(kind.rawValue) \(reach(r, grantNote))"
        // One line whatever the error printed, since the scope is one line.
        case .blind(let kind, let why, let grant):
            "\(kind.rawValue) could not look (\(why.split(whereSeparator: \.isNewline).joined(separator: " "))\(grant ? grantNote : ""))"
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

/// Reads with the chosen reader and prints. The one place the verbs meet the screen.
@MainActor
func look(_ query: Query, source: SourceKind, wait: Wait? = nil) async throws {
    print(try await Report.text(query, source: source, wait: wait) { @MainActor in try await $0.reader.judged($1) })
}

extension Report {
    /// A query's reading as the text the verbs print and the MCP tools answer: one read, or
    /// with a wait, the read the wait ended on, its scope line led by how the wait went.
    /// [LAW:one-source-of-truth]
    static func text(
        _ query: Query, source: SourceKind, wait: Wait? = nil, grantNote: String = "",
        reading read: @Sendable (SourceKind, Query) async throws -> Judged
    ) async throws -> String {
        // [LAW:nothing-unseen] One event per look, from the one path every verb and tool
        // reads through: which reader, what it read, and how it ended.
        try await Telemetry.unit("look", outcome: \.outcome) {
            Telemetry.note("source", source.rawValue)
            Telemetry.note("region", query.region.kind)
            Telemetry.note("order", query.near == nil ? "reading" : "near")
            Telemetry.note("role", query.role?.rawValue ?? "none")
            // Tallied as each read starts, so a look that fails says how many it spent.
            Telemetry.count("reads", 0)
            Telemetry.count("box_ms", 0)
            // The boxes' checks timed apart from the read, wherever they run - after a read,
            // or at the end of a wait.
            func counted(_ query: Query) async throws -> Judged {
                Telemetry.tally("reads")
                let judged = try await read(source, query)
                return Judged(judged.reading) { _, deadline in
                    let start = ContinuousClock.now
                    defer { Telemetry.tally("box_ms", by: Int((ContinuousClock.now - start) / .milliseconds(1))) }
                    return try await judged.pressed(until: deadline)
                }
            }
            guard let wait else {
                let reading = try await counted(query).pressed()
                Self.count(reading, query)
                return (text: lines(reading, query: query, source: source, grantNote: grantNote).joined(separator: "\n"),
                        outcome: reading.outcome.said)
            }
            Telemetry.note("until", wait.until.rawValue)
            let waited = try await waiting(for: wait, on: query, read: counted)
            Self.count(waited.reading, query)
            let said = lines(waited.reading, query: query, source: source, grantNote: grantNote)
            return (text: ([waitedClause(waited, wait) + said[0]] + said.dropFirst()).joined(separator: "\n"),
                    outcome: waited.settled ? "settled" : "timed_out")
        }.text
    }

    /// The counts of the reading a look ended on, zeros included.
    private static func count(_ reading: Reading, _ query: Query) {
        Telemetry.count("examined", reading.scope.examined)
        Telemetry.count("boxes_narrowed", reading.scope.boxes.narrowed)
        for (why, count) in reading.scope.boxes.unchecked { Telemetry.count("boxes_unchecked_\(why.rawValue)", count) }
        Telemetry.count("box_calls", reading.scope.boxes.calls)
        for why in Exclusion.Reason.allCases {
            Telemetry.count("excluded_\(why.rawValue)", reading.scope.excluded.first { $0.reason == why }?.count ?? 0)
        }
        // How many processes' windows a front look took in; every other region reads them all.
        if case .only(let pids) = reading.scope.owners { Telemetry.count("owners", pids.count) }
        Telemetry.note("reach", reading.scope.reach.kind)
        switch reading.outcome {
        case .matched(let m):
            Telemetry.count("matched", m.count)
            Telemetry.count("nearest", 0)
            // Rows matched by another of their element's texts than the one they show.
            Telemetry.count("matched_also", m.all.filter { if case .also = query.match.fit($0) { true } else { false } }.count)
        case .nearest(let n), .unanchored(let n):
            Telemetry.count("matched", 0)
            Telemetry.count("nearest", n.count)
            Telemetry.count("matched_also", 0)
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
    /// The app eyes answers to: every running process of the app responsible for this one,
    /// matched by where it runs from, never by name - two apps can share one. The one place
    /// it is derived, for a front look and a hit alike. [LAW:one-source-of-truth]
    @MainActor
    static func current() async throws -> Front.Passed {
        let holder = try await Holder.current()
        let path = { (url: URL?) in url?.resolvingSymlinksInPath().path }
        let holderPath = path(URL(fileURLWithPath: holder.path))
        let own = NSWorkspace.shared.runningApplications.filter { path($0.bundleURL ?? $0.executableURL) == holderPath }
        return Front.Passed(pids: Set(own.map(\.processIdentifier)), name: holder.name)
    }
}

extension Front {
    /// The app a look naming one reads now, from the apps running and the windows on screen.
    @MainActor
    static func now(named name: String, own: Passed, listing: WindowListing, displays: [Display]) throws(AppUnread) -> Front {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return try named(name, own: own, running: running.map { App(pid: $0.processIdentifier, name: $0.localizedName) },
                         listing: listing, displays: displays)
    }

    /// What a look with no place named reads now, with the app eyes answers to and the window
    /// listing the caller already holds, so a hit judges the listing it found the window in.
    @MainActor
    static func now(own: Passed, listing: WindowListing, displays: [Display]) throws(NoFront) -> Front {
        let running = NSWorkspace.shared.runningApplications
        return try choose(
            frontmost: App.now(),
            own: own,
            regular: Set(running.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)),
            names: Dictionary(running.compactMap { app in app.localizedName.map { (app.processIdentifier, $0) } }, uniquingKeysWith: { a, _ in a }),
            listing: listing,
            displays: displays)
    }
}
