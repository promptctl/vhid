import ArgumentParser
import CoreGraphics
import Eyes
import Grants
import Pixels
import Telemetry
import Tree

/// How a caller spells an argument's name in a refusal: `--limit` on the command line,
/// `limit` to an MCP client.
enum Spelling {
    case flag, argument

    func callAsFunction(_ name: String) -> String { self == .flag ? "--\(name)" : name }
}

/// What each argument means, said once for a verb's help and its MCP tool's schema.
/// [LAW:one-source-of-truth]
enum Help {
    static let text = "The text to look for. Matches any run that contains it."
    static let exact = "Match only a run that is exactly this text."
    static let edits = "Match a run within this many single-character edits of the text, for recogniser slips."
    static let display = "Read this display, by its window-server id, which `eyes displays` lists and every scope line names. Defaults to the main display."
    static let window = "Read this window's bounds, by the id `eyes windows` prints."
    static let rect = "Read this rectangle: x,y,width,height in the points vhid clicks, the form each row's box prints in."
    static let page = "Read the web page this window shows, by the id `eyes windows` prints: the page alone,"
        + " not the browser's toolbar and bookmarks around it. Needs Accessibility, which finds the page."
    static let near = "Order the matches by how close each sits to a run containing this text, nearest first:"
        + " the Remove in Beta's row before the others. With nothing on screen containing it, no match is answered:"
        + " which one was meant is unknown, and a wait settles neither present nor absent."
    static let until = "Read again until the text is present or absent, then answer once with the last reading."
        + " Absent counts only a region read whole, twice running."
    static let timeout = "With until, the most seconds to wait: at most \(Int(Wait.longest)). A wait that runs out answers"
        + " with its last reading and says it timed out. Defaults to \(Int(Wait.defaultSeconds))."
    static let source = "Which reader looks: tree (the accessibility tree: exact text and roles),"
        + " pixels (recognised text, anything drawn), or merged (both, each thing reported once;"
        + " answers with either grant, naming a reader that could not look). Defaults to merged. " + needs
    /// Which grant each reader needs, built from the one mapping. [LAW:one-source-of-truth]
    static let needs = Grant.allCases.sorted { $0.reader.rawValue > $1.reader.rawValue }
        .map { "The \($0.reader.rawValue) reader needs \($0.name)" }.joined(separator: " and ") + "."
}

/// Which reader a verb or tool reads with: every kind a reader can be. [LAW:one-source-of-truth]
extension SourceKind: ExpressibleByArgument {
    /// The reader of this kind. Merged puts the tree first, so where both saw a thing its
    /// exact frame and role are the ones kept.
    @MainActor var reader: any Reader {
        switch self {
        case .tree: TreeReader(granted: Self.granted)
        case .pixels: PixelReader(granted: Self.granted)
        case .merged: MergedReader(TreeReader(granted: Self.granted), PixelReader(granted: Self.granted), locate: { try $0.bounds() })
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
    @Option(help: .init(stringLiteral: Help.display))
    var display: UInt32?

    @Option(help: .init(stringLiteral: Help.window))
    var window: UInt32?

    /// Takes the next argument whatever it starts with: a box on a display left of or
    /// above the main one starts with a minus, which would otherwise read as a flag.
    @Option(parsing: .unconditional, help: .init(stringLiteral: Help.rect))
    var rect: String?

    @Option(help: .init(stringLiteral: Help.page))
    var page: UInt32?

    func validate() throws {
        _ = try Self.place(display: display, window: window, page: page, rect: rect, as: .flag)
    }

    @MainActor var region: Region {
        get async throws { try await Self.place(display: display, window: window, page: page, rect: rect, as: .flag).region() }
    }

    /// The one place a region is spelled from its four arguments, for the verbs and the
    /// MCP tools alike, each naming an argument the way its caller spells it.
    /// [LAW:single-enforcer]
    ///
    /// The main display is the default rather than every display, because `Region` has no
    /// word for everywhere; the scope line names which display was read, so the default is
    /// never mistaken for the whole desk.
    static func place(display: UInt32?, window: UInt32?, page: UInt32?, rect: String?, as s: Spelling) throws -> Place {
        guard [display != nil, window != nil, page != nil, rect != nil].filter({ $0 }).count <= 1 else {
            throw ValidationError("give at most one of \(s("display")), \(s("window")), \(s("page")), \(s("rect"))")
        }
        return try page.map(Place.page) ?? .region(
            rect.map { .rect(try parsedRect($0, as: s)) }
                ?? window.map(Region.window)
                ?? .display(display ?? CGMainDisplayID()))
    }

    /// Where a verb was told to look: a region as spelled, or a window's web page, whose
    /// frame only the tree can find - so it is found when the look is made, not when the
    /// arguments are parsed.
    enum Place {
        case region(Region)
        case page(UInt32)

        /// What a window's tree says of its pages: the tree in the process, a fake in a test.
        typealias Pages = @Sendable @MainActor (UInt32) async throws -> Paged
        static let tree: Pages = { try await TreeReader(granted: SourceKind.granted).pages(in: $0) }

        @MainActor func region(pages: Pages = tree) async throws -> Region {
            switch self {
            case .region(let region): region
            case .page(let id): try await Self.page(id, pages: pages)
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
                Telemetry.note("reach", paged.stop?.kind ?? "whole")
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
        let parts = spelled.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
              [x, y, w, h].allSatisfy({ abs($0) <= 1_000_000 }), w > 0, h > 0
        else { throw ValidationError("\(s("rect")) wants x,y,width,height in points - a positive size, nothing past a million - got \(spelled)") }
        return ScreenRect(x: x, y: y, width: w, height: h)
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
        let asked = query.match.map { match in wanted(match) + (query.near.map { " near \(wanted($0))" } ?? "") }
        let head: String = switch reading.outcome {
        case .matched(let m):
            asked.map { "\(m.count) matched \($0)" } ?? "\(m.count) run\(m.count == 1 ? "" : "s")"
        case .nearest:
            asked.map { "\($0) not found" } ?? "no text"
        case .unanchored:
            // The near misses that follow are the anchor's, so the anchor is what is named
            // not found. [LAW:no-silent-failure]
            "\(query.near.map(wanted) ?? "") not found to place \(query.match.map(wanted) ?? "the text") near"
        }
        let clauses: [String?] = [
            "\(head) in \(place(query.region)) \(s.region) \(looked(source, s.reach))",
            "\(s.examined) run\(s.examined == 1 ? "" : "s") read",
            s.excluded.isEmpty ? nil : s.excluded.map { "\($0.count) \($0.reason.rawValue)" }.joined(separator: ", "),
            reach(s.reach, grantNote),
            reading.outcome.misses.isEmpty ? nil : "nearest follow",
        ]
        return clauses.compactMap { $0 }.joined(separator: "; ") + ". Each row's point is the centre of its box, x,y,width,height, in vhid click coordinates."
    }

    /// One run per row: the centre a click lands on, the box it is the centre of, the
    /// text, and what it is - the role the tree gave it, or `pixels` for text only the
    /// pixels reader saw, which has none. The nearest rows add how many edits off they were.
    static func rows(_ outcome: Outcome) -> [String] {
        switch outcome {
        case .matched(let m): m.all.map(row)
        case .nearest(let near), .unanchored(let near): near.map { "\(row($0.found))\t\($0.distance) off" }
        }
    }

    private static func row(_ found: Found) -> String {
        "\(point(found.frame.centre))\t\(box(found.frame))\t\(found.text)\t\(found.source.role?.rawValue ?? "pixels")"
    }

    /// A frame as `rect` takes it, so a box is copied into a narrower look as printed.
    /// Whole points rounded outward, the smallest such box covering the frame, which is
    /// what keeps the rounded centre beside it inside it. [LAW:one-source-of-truth]
    static func box(_ r: ScreenRect) -> String {
        let (x, y) = (r.x.rounded(.down), r.y.rounded(.down))
        let (right, bottom) = ((r.x + r.width).rounded(.up), (r.y + r.height).rounded(.up))
        return "\(Int(x)),\(Int(y)),\(Int(right - x)),\(Int(bottom - y))"
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

    private static func point(_ p: ScreenPoint) -> String { "\(Int(p.x.rounded())),\(Int(p.y.rounded()))" }
}

private extension Paged.Stop {
    /// Why a page search stopped short, for the page's event.
    var kind: String {
        switch self {
        case .elementLimit: "element_limit"
        case .timeBudget: "time_budget"
        case .unread: "unread"
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
    print(try await Report.text(query, source: source, wait: wait) { @MainActor in try await $0.reader.read($1) })
}

extension Report {
    /// A query's reading as the text the verbs print and the MCP tools answer: one read, or
    /// with a wait, the read the wait ended on, its scope line led by how the wait went.
    /// [LAW:one-source-of-truth]
    static func text(
        _ query: Query, source: SourceKind, wait: Wait? = nil, grantNote: String = "",
        reading read: @Sendable (SourceKind, Query) async throws -> Reading
    ) async throws -> String {
        // [LAW:nothing-unseen] One event per look, from the one path every verb and tool
        // reads through: which reader, what it read, and how it ended.
        try await Telemetry.unit("look", outcome: \.outcome) {
            Telemetry.note("source", source.rawValue)
            Telemetry.note("region", query.region.kind)
            Telemetry.note("order", query.near == nil ? "reading" : "near")
            // Tallied as each read starts, so a look that fails says how many it spent.
            Telemetry.count("reads", 0)
            func counted(_ query: Query) async throws -> Reading { Telemetry.tally("reads"); return try await read(source, query) }
            guard let wait else {
                let reading = try await counted(query)
                Self.count(reading)
                return (text: lines(reading, query: query, source: source, grantNote: grantNote).joined(separator: "\n"),
                        outcome: reading.outcome.said)
            }
            Telemetry.note("until", wait.until.rawValue)
            let waited = try await waiting(for: wait, on: query, read: counted)
            Self.count(waited.reading)
            let said = lines(waited.reading, query: query, source: source, grantNote: grantNote)
            return (text: ([waitedClause(waited, wait) + said[0]] + said.dropFirst()).joined(separator: "\n"),
                    outcome: waited.settled ? "settled" : "timed_out")
        }.text
    }

    /// The counts of the reading a look ended on, zeros included.
    private static func count(_ reading: Reading) {
        Telemetry.count("examined", reading.scope.examined)
        switch reading.outcome {
        case .matched(let m): Telemetry.count("matched", m.count); Telemetry.count("nearest", 0)
        case .nearest(let n), .unanchored(let n): Telemetry.count("matched", 0); Telemetry.count("nearest", n.count)
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
