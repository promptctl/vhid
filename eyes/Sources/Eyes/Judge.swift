/// Turning what a reader saw into a `Reading`: which candidates match, which are nearest
/// when none do, and what the limit cut.
///
/// [LAW:single-enforcer] Every reader hands its candidates here rather than deciding
/// matches itself, so "matches" means one thing whichever reader looked, and a merged
/// reader later reconciles two answers that were judged by the same rule.
/// [LAW:effects-at-boundaries] Pure: no capture, no display, so every verdict a caller
/// acts on is checked by a test with a list a test wrote.
public extension Reading {
    /// How many near misses a failed query carries: enough to tell a slip from an absence,
    /// few enough to cost a handful of rows.
    static let nearestShown = 3

    /// - Parameters:
    ///   - candidates: everything the reader recognised in `region`, in reading order.
    ///   - examined: how many runs the reader looked at, including ones it could not use.
    ///   - excluded: what the reader dropped before judging, and why.
    static func judging(
        _ candidates: [Found],
        query: Query,
        region: ScreenRect,
        examined: Int,
        excluded: [Exclusion]
    ) -> Reading {
        let scored = candidates.map { (found: $0, distance: query.match.distance(to: $0.text.value)) }
        let matching = scored.filter { query.match.tolerates($0.distance) }.map { query.match.narrowing($0.found) }
        let kept = Array(matching.prefix(query.limit.count))
        let cut = matching.count - kept.count

        let outcome: Outcome = Matches(kept).map(Outcome.matched)
            ?? .nearest(
                scored.sorted { $0.distance < $1.distance }
                    .prefix(nearestShown)
                    .map { Near(found: $0.found, distance: $0.distance) }
            )
        let scope = Scope(
            region: region,
            examined: examined,
            excluded: excluded + (cut > 0 ? [Exclusion(reason: .ranked, count: cut)] : []),
            reach: cut > 0 ? .stopped(.resultLimit(query.limit)) : .whole
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
    func narrowing(_ found: Found) -> Found { map { $0.narrowing(found) } ?? found }
}

extension Match {
    /// Edits between what was asked for and `text`, measured the way this match compares.
    ///
    /// `contains` measures against the best-fitting stretch of the text, so "Save" inside
    /// "Save As…" is zero and "Sve" inside it is one. The other two measure the whole run.
    /// Case never counts, for the reason `Match` gives.
    func distance(to text: String) -> Int {
        switch self {
        case .exact(let wanted), .within(_, let wanted):
            Self.edits(from: wanted, to: text, anywhere: false)
        case .contains(let wanted):
            Self.edits(from: wanted, to: text, anywhere: true)
        }
    }

    /// A `contains` match is narrowed to the fewest whole words holding what was asked
    /// for, so its centre is on the asked-for text rather than on the middle of a longer
    /// run. The others matched the whole run and report it whole. A query that only fits
    /// across the words' own spacing keeps the whole run, which still holds it.
    func narrowing(_ found: Found) -> Found {
        guard case .contains(let wanted) = self else { return found }
        let words = found.words
        let spans = words.indices.flatMap { start in words.indices[start...].map { start...$0 } }
        let holding = spans.filter { span in
            Text(joining: words[span].map(\.text)).value.localizedCaseInsensitiveContains(wanted)
        }
        return holding.min { $0.count < $1.count }.map { span in
            Found(first: words[span.lowerBound], rest: Array(words[span].dropFirst()), source: found.source)
        } ?? found
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
