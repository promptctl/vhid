import ScreenSpace

/// Two readers asked the same query, what they saw reconciled into one answer.
///
/// It holds each as `any Reader` and nothing more, so neither the readers nor this type
/// knows which kinds it holds - the tree and the pixels compose here without either
/// linking the other. [LAW:composability] The order is a priority: where both saw the
/// same thing, the first reader's words and frame are the ones kept.
public struct MergedReader: Reader {
    public let source = SourceKind.merged
    let first: any Reader
    let second: any Reader
    let locate: Locate

    /// `locate` is how the region is resolved before either reader is asked: `Region.bounds`
    /// in the binary, a fixed answer in a test, which then reads no display of the host's.
    /// [LAW:effects-at-boundaries]
    public init(_ first: any Reader, _ second: any Reader, locate: @escaping Locate) {
        self.first = first
        self.second = second
        self.locate = locate
    }

    /// Asks both as child tasks: both readers are main-actor, so they overlap only where
    /// one leaves it - Vision's recognition does, the tree's walk does not - and the screen
    /// has less time to change between the two looks than asking one after the other.
    /// Throws when the region names nowhere, once, before either reader is asked; when
    /// neither could look; or when the task was cancelled. One reader that could not look -
    /// a window gone between the merge's look and its own included - is part of the
    /// answer, carried in the scope, and never proof of absence.
    public func look(_ query: Query, on layout: DisplayLayout) async throws -> Candidates {
        _ = try locate(query.region, layout)
        async let a = Self.attempt(first, query, layout)
        async let b = Self.attempt(second, query, layout)
        return try Candidates.merging(try await a, try await b)
    }

    /// Each reader checks the boxes it placed: a row found by both carries the first
    /// reader's placing, and the second leaves it as the first left it.
    public func pressing(_ reading: Reading, until deadline: ContinuousClock.Instant) async throws -> Reading {
        try await second.pressing(try await first.pressing(reading, until: deadline), until: deadline)
    }

    private static func attempt(_ reader: any Reader, _ query: Query, _ layout: DisplayLayout) async throws -> Attempt {
        do {
            return .looked(reader.source, try await reader.look(query, on: layout))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .blind(reader.source, error)
        }
    }
}

/// One reader's answer to a merged look: what it saw, or why it could not look.
public enum Attempt: Sendable {
    case looked(SourceKind, Candidates)
    case blind(SourceKind, any Error)

    var part: Part {
        switch self {
        case .looked(let kind, let seen): .read(kind, seen.reach)
        case .blind(let kind, let error): .blind(kind, String(describing: error), missingGrant: (error as? ReaderError)?.missingGrant ?? false)
        }
    }

    var seen: Candidates? { if case .looked(_, let c) = self { c } else { nil } }
}

/// Neither reader of a merged read could look, so there is nothing to answer with. Both
/// errors are kept as thrown, so a caller can still tell a missing grant by its type.
public struct BothBlind: Error, CustomStringConvertible {
    public let first: any Error
    public let second: any Error

    public init(first: any Error, second: any Error) {
        self.first = first
        self.second = second
    }

    public var description: String { "neither reader could look: \(first); \(second)" }
}

public extension Candidates {
    /// What two readers saw, as what one merged reader saw.
    ///
    /// A stretch of the second reader's run that says what one of the first reader's
    /// finds says, at a place that intersects it, is that find seen twice: the first's
    /// copy is kept with its source `.merged` of both, and the stretch is counted as a
    /// `duplicate`. Stretches, not whole runs, because the readers divide text
    /// differently - Vision reads a menu bar as one run where the tree has an element per
    /// menu - and what is left of the run after its seen-twice stretches stays, in pieces.
    /// "Says the same" forgives a recogniser's slip, one edit in five characters; two
    /// finds of one reader are never merged with each other. Each piece left is placed as
    /// its run was, within the run's bound, and a piece no display shows is `unshown`.
    ///
    /// The region is where both looked. The reach is whole only when both readers read
    /// it whole; otherwise it names each reader's reach, and a reader that threw is
    /// named blind - so the other's empty answer never proves an absence over a region
    /// half of the merge did not see. [LAW:no-silent-failure] Pure, so every rule is
    /// tested with candidates a test wrote. [LAW:effects-at-boundaries]
    static func merging(_ a: Attempt, _ b: Attempt) throws -> Candidates {
        if case .blind(_, let e1) = a, case .blind(_, let e2) = b { throw BothBlind(first: e1, second: e2) }
        let seen = [a.seen, b.seen].compactMap { $0 }
        var kept = a.seen?.found ?? []
        let firsts = kept.count
        var merged = Set<Int>()
        var extra: [Found] = []
        var duplicates = 0, unshown = 0
        // What is left of `run` between its seen-twice stretches, placed as the run was.
        func split(_ loose: [Word], of run: Found) {
            guard let head = loose.first else { return }
            do { extra.append(try Found(first: head, rest: Array(loose.dropFirst()), source: run.source, placedAs: run)) } catch { unshown += 1 }
        }
        for run in b.seen?.found ?? [] {
            var loose: [Word] = []
            let words = run.words
            var i = 0
            while i < words.count {
                // The closest-saying stretch from here, the longer on a tie: the longest
                // one within the slip allowance would carry a neighbour along - "Downloads 3"
                // is one edit from "Downloads", and the badge only the pixels saw is lost.
                let hit = (i..<words.count).flatMap { j in
                    (0..<firsts).compactMap { k in kept[k].edits(to: Array(words[i...j])).map { (index: k, end: j, edits: $0) } }
                }.min { ($0.edits, -$0.end) < ($1.edits, -$1.end) }
                guard let (index, end, _) = hit else {
                    loose.append(words[i])
                    i += 1
                    continue
                }
                if merged.insert(index).inserted {
                    kept[index] = kept[index].seen(by: .merged(kept[index].source, run.source))
                }
                duplicates += 1
                split(loose, of: run)
                loose = []
                i = end + 1
            }
            split(loose, of: run)
        }
        let regions = seen.map(\.region)
        let both = regions.dropFirst().reduce(Optional(regions[0])) { $0?.intersection($1) }
        return Candidates(
            found: (kept + extra).inReadingOrder,
            region: both ?? seen[0].region,
            examined: seen.map(\.examined).reduce(0, +),
            excluded: (seen.flatMap(\.excluded) + [Exclusion(reason: .duplicate, count: duplicates), Exclusion(reason: .unshown, count: unshown)]).summed,
            reach: a.part.isWhole && b.part.isWhole ? .whole : .stopped(.merged(a.part, b.part)),
            // A reader that could not look took in nobody's windows.
            owners: seen.map(\.owners).reduce(.only([])) { $0.union($1) }
        )
    }
}

private extension Found {
    /// Edits between this row's text and a stretch's, whitespace ignored, when they say the
    /// same thing where this row is shown - one edit in five characters forgiven - and nil
    /// when they do not.
    func edits(to stretch: [Word]) -> Int? {
        guard stretch.contains(where: { $0.frame.intersects(part) }) else { return nil }
        let a = text.value.filter { !$0.isWhitespace }, b = Text(joining: stretch.map(\.text)).value.filter { !$0.isWhitespace }
        let edits = Match.edits(from: a, to: b, anywhere: false)
        return edits <= max(a.count, b.count) / 5 ? edits : nil
    }
}
