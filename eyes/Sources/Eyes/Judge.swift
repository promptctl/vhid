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

    public init(found: [Found], region: ScreenRect, examined: Int, excluded: [Exclusion], reach: Reach) {
        self.found = found
        self.region = region
        self.examined = examined
        self.excluded = excluded
        self.reach = reach
    }
}

public extension Reading {
    static func judging(_ seen: Candidates, query: Query) -> Reading {
        judging(seen.found, query: query, region: seen.region, examined: seen.examined, excluded: seen.excluded, reach: seen.reach)
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
        reach: Reach
    ) -> Reading {
        let scored = candidates.map { (found: $0, distance: query.match.distance(to: $0.text.value)) }
        let matching = scored.filter { query.match.tolerates($0.distance) }.flatMap { query.match.narrowing($0.found) }
        // Absent `near` is one anchor everywhere at once: every match beside it, reading
        // order kept by the stable sort. [LAW:dataflow-not-control-flow]
        let anchors = query.near.map { near in candidates.filter { near.tolerates(near.distance(to: $0.text.value)) }.flatMap(near.narrowing) }
        func misses(_ wanted: Match?) -> [Near] {
            candidates.map { (found: $0, distance: wanted.distance(to: $0.text.value)) }
                .sorted { $0.distance < $1.distance }
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

        let outcome: Outcome = unanchored ? .unanchored(misses(query.near))
            : Matches(kept).map(Outcome.matched) ?? .nearest(misses(query.match))
        let scope = Scope(
            region: region,
            examined: examined,
            excluded: excluded + (cut > 0 ? [Exclusion(reason: .ranked, count: cut)] : []),
            reach: reach == .whole && cut > 0 ? .stopped(.resultLimit(query.limit)) : reach
        )
        return Reading(outcome: outcome, scope: scope)
    }
}

extension Optional where Wrapped == Match {
    /// An absent match asks for everything, which is a match every candidate meets at
    /// distance zero rather than a branch that skips the judging.
    /// [LAW:dataflow-not-control-flow]
    func distance(to text: String) -> Int { map { $0.distance(to: text) } ?? 0 }
    func tolerates(_ distance: Int) -> Bool { map { $0.tolerates(distance) } ?? true }
    func narrowing(_ found: Found) -> [Found] { map { $0.narrowing(found) } ?? [found] }
}

extension Match {
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
    func narrowing(_ found: Found) -> [Found] {
        switch self {
        case .exact: [found]
        case .contains, .within: narrowed(found)
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
