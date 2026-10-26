/// Turning what a reader saw into a `Reading`: which candidates match, which are nearest
/// when none do, and what the limit cut.
///
/// [LAW:single-enforcer] Every reader hands its candidates here rather than deciding
/// matches itself, so "matches" means one thing whichever reader looked, and a merged
/// reader later reconciles two answers that were judged by the same rule.
/// [LAW:effects-at-boundaries] Pure: no capture, no display, so every verdict a caller
/// acts on is checked by a test with a list a test wrote.
/// What a reader saw in a region, before it is judged against a query.
public struct Candidates: Sendable, Hashable {
    /// Everything recognised in `region`, in reading order.
    public let found: [Found]
    /// The rectangle that was looked at, resolved from the query's region.
    public let region: ScreenRect
    /// How many runs the reader looked at, including ones it could not use.
    public let examined: Int
    /// What the reader dropped before judging, and why.
    public let excluded: [Exclusion]
    /// How far the reader itself got.
    public let reach: Reach
    /// Whose windows were read: every process's, or the front's owners at this read.
    public let owners: Owners

    public init(found: [Found], region: ScreenRect, examined: Int, excluded: [Exclusion], reach: Reach, owners: Owners) {
        self.found = found
        self.region = region
        self.examined = examined
        self.excluded = excluded
        self.reach = reach
        self.owners = owners
    }
}

public extension Reading {
    static func judging(_ seen: Candidates, query: Query) -> Reading {
        judging(seen.found, query: query, region: seen.region, examined: seen.examined, excluded: seen.excluded, reach: seen.reach, owners: seen.owners)
    }

    /// How many near misses a failed query carries: enough to tell a slip from an absence,
    /// few enough to cost a handful of rows.
    static let nearestShown = 3

    /// - Parameters:
    ///   - candidates: everything the reader recognised in `region`, in reading order.
    ///   - examined: how many runs the reader looked at, including ones it could not use.
    ///   - excluded: what the reader dropped before judging, and why.
    ///   - reach: how far the reader itself got. A reader that stopped short stays stopped
    ///     whatever the limit does; one that got through is stopped only by the limit.
    static func judging(
        _ candidates: [Found],
        query: Query,
        region: ScreenRect,
        examined: Int,
        excluded: [Exclusion],
        reach: Reach,
        owners: Owners
    ) -> Reading {
        // [LAW:single-enforcer] Text first, then role, then one row per place, then narrowed
        // to the words: a role or a duplicate is judged only of what says the text asked for.
        let fitting = candidates.map { (found: $0, fit: query.match.fit($0)) }.filter { query.match.tolerates($0.fit.distance) }
        let cast = Dictionary(grouping: fitting) { query.role.cast($0.found) }
        let admitted = distinct(cast[.admitted] ?? [], by: \.found)
        let matching = admitted.kept.flatMap { query.match.narrowing($0.found, by: $0.fit) }
        // Absent `near` is one anchor everywhere at once: every match beside it, reading
        // order kept by the stable sort. Anchors are any text on screen, whatever its role.
        // [LAW:dataflow-not-control-flow]
        let anchors = query.near.map { near in
            distinct(candidates.map { (found: $0, fit: near.fit($0)) }.filter { near.tolerates($0.fit.distance) }, by: \.found).kept
                .flatMap { near.narrowing($0.found, by: $0.fit) }
        }
        // The rows a miss shows: the asked-for text's of the asked-for role, the anchor's of any.
        func misses(_ wanted: Match?, among pool: [Found]) -> [Near] {
            distinct(pool.map { (found: $0, distance: wanted.fit($0).distance) }.sorted { $0.distance < $1.distance }, by: \.found).kept
                .prefix(nearestShown)
                .map { Near(found: $0.found, distance: $0.distance) }
        }
        // Nothing matching is an absence whatever the anchor. Matches with named text
        // nowhere to stand beside are neither found nor gone: which one was meant is
        // unknown, so none is answered, and the rows are that text's own near misses.
        let unanchored = !matching.isEmpty && anchors?.isEmpty == true
        let ordered = unanchored ? [] : anchors.map { anchors in
            matching.map { m in (m, anchors.map { m.frame.gap(to: $0.frame) }.min()!) }
                .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
        } ?? matching
        let kept = Array(ordered.prefix(query.limit.count))
        let cut = ordered.count - kept.count

        let outcome: Outcome = unanchored ? .unanchored(misses(query.near, among: candidates))
            : Matches(kept).map(Outcome.matched) ?? .nearest(misses(query.match, among: candidates.filter { query.role.cast($0) == .admitted }))
        // Rows set aside for their role are things on screen too, each counted once.
        let unknown = distinct(cast[.unknown] ?? [], by: \.found).kept.count
        let set: [Exclusion] = [Exclusion(reason: .duplicate, count: admitted.dropped),
                                Exclusion(reason: .otherRole, count: distinct(cast[.other] ?? [], by: \.found).kept.count),
                                Exclusion(reason: .roleUnknown, count: unknown), Exclusion(reason: .ranked, count: cut)]
        let scope = Scope(
            region: region,
            examined: examined,
            // A reader's own duplicates and the judge's are one count. [LAW:one-source-of-truth]
            excluded: (excluded + set).summed,
            reach: reach != .whole ? reach : unknown > 0 ? .stopped(.unread) : cut > 0 ? .stopped(.resultLimit(query.limit)) : reach,
            owners: owners
        )
        return Reading(outcome: outcome, scope: scope)
    }
}

extension Optional where Wrapped == Match {
    /// An absent match asks for everything, which is a match every candidate meets at
    /// distance zero rather than a branch that skips the judging.
    /// [LAW:dataflow-not-control-flow]
    public func fit(_ found: Found) -> Fit { map { $0.fit(found) } ?? .drawn(0) }
    func tolerates(_ distance: Int) -> Bool { map { $0.tolerates(distance) } ?? true }
    func narrowing(_ found: Found, by fit: Fit) -> [Found] { map { $0.narrowing(found, by: fit) } ?? [found] }
}

/// Which of a row's texts a match fits best, and how many edits off: its own text, or one of
/// the other things its element says in words. Derived wherever it is needed, never stored on
/// the row, so a row cannot disagree with how it matched. [LAW:one-source-of-truth]
public enum Fit: Sendable, Hashable {
    case drawn(Int)
    case also(Words, Int)

    public var distance: Int {
        switch self {
        case .drawn(let d), .also(_, let d): d
        }
    }
}

/// How a row stands to the role asked for.
enum Cast: Hashable {
    /// Of the role, or no role was asked for.
    case admitted
    /// The tree named another role.
    case other
    /// No reader that knows roles saw it.
    case unknown
}

extension Optional where Wrapped == Role {
    /// Absent asks for every role, which every row is cast in. [LAW:dataflow-not-control-flow]
    func cast(_ found: Found) -> Cast {
        map { asked in found.source.role.map { $0 == asked ? .admitted : .other } ?? .unknown } ?? .admitted
    }
}

/// One text at one place, whatever role said it: a cell and the label inside it are two
/// elements and one thing on screen. Each row list a reading prints passes through here, the
/// first of each place kept, so the rows a reading answers and the near misses it shows say
/// one thing once. [LAW:single-enforcer]
func distinct<Row>(_ rows: [Row], by found: (Row) -> Found) -> (kept: [Row], dropped: Int) {
    var seen: Set<Place> = []
    let kept = rows.filter { seen.insert(Place(text: found($0).text.value, frame: found($0).frame)).inserted }
    return (kept, rows.count - kept.count)
}

private struct Place: Hashable {
    let text: String
    let frame: ScreenRect
}

extension Match {
    /// The row's text or the first of its element's other words at the least distance, the
    /// row's own text on a tie.
    func fit(_ found: Found) -> Fit {
        ([.drawn(distance(to: found.text.value))] + found.source.also.map { .also($0, distance(to: $0.text.value)) })
            .min { $0.distance < $1.distance }!
    }

    /// Edits between what was asked for and `text`, measured the way this match compares.
    ///
    /// `exact` measures the whole run. The other two measure the best-fitting stretch of
    /// it, so "Save" inside "Save As…" is zero and "Sve" inside it is one - and so a
    /// `find` that printed a run as one off matches it when widened with one edit, rather
    /// than being narrowed by the widening. Case never counts, for the reason `Match` gives.
    func distance(to text: String) -> Int {
        switch self {
        case .exact(let wanted): Self.edits(from: wanted, to: text, anywhere: false)
        case .contains(let wanted), .within(_, let wanted): Self.edits(from: wanted, to: text, anywhere: true)
        }
    }

    /// The match as the stretches of words that hold it, so each point is on the asked-for
    /// text rather than on the middle of a longer run - and a run holding it twice is two
    /// matches, not one with the second dropped uncounted. Shortest stretches win, and no
    /// two share a word. `exact` matched the whole run and reports it whole, as does a
    /// match that only fits across the words' own spacing.
    /// A row matched by another of its element's texts answers whole: those words have no
    /// place of their own to narrow to.
    func narrowing(_ found: Found, by fit: Fit) -> [Found] {
        switch (self, fit) {
        case (.exact, _), (_, .also): [found]
        case (.contains, .drawn), (.within, .drawn): narrowed(found)
        }
    }

    private func narrowed(_ found: Found) -> [Found] {
        let words = found.words
        let spans = words.indices.flatMap { start in words.indices[start...].map { start...$0 } }
            .filter { tolerates(distance(to: Text(joining: words[$0].map(\.text)).value)) }
            .sorted { ($0.count, $0.lowerBound) < ($1.count, $1.lowerBound) }
        var chosen: [ClosedRange<Int>] = []
        for span in spans where !chosen.contains(where: { $0.overlaps(span) }) {
            chosen.append(span)
        }
        let narrowed = chosen.sorted { $0.lowerBound < $1.lowerBound }.map { span in
            Found(first: words[span.lowerBound], rest: Array(words[span].dropFirst()), source: found.source)
        }
        return narrowed.isEmpty ? [found] : narrowed
    }

    func tolerates(_ distance: Int) -> Bool {
        switch self {
        case .exact, .contains: distance == 0
        case .within(let edits, _): distance <= edits.count
        }
    }

    /// Levenshtein distance, or with `anywhere` the distance to the closest substring of
    /// `text` - the same table, with the text's start and end made free.
    static func edits(from wanted: String, to text: String, anywhere: Bool) -> Int {
        let a = Array(wanted.lowercased()), b = Array(text.lowercased())
        var row = (0...b.count).map { anywhere ? 0 : $0 }
        for (i, wantedChar) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, textChar) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (wantedChar == textChar ? 0 : 1))
                diagonal = above
            }
        }
        return anywhere ? row.min()! : row[b.count]
    }
}
