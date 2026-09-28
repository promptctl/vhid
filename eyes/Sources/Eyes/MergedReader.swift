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

    public init(_ first: any Reader, _ second: any Reader) {
        self.first = first
        self.second = second
    }

    /// Asks both at once, so the screen has as little time as possible to change between
    /// the two looks, and a reader's work off the main actor - Vision's - overlaps the
    /// other's. Throws only when neither could look, or when the task was cancelled: one
    /// reader that could not look is part of the answer, carried in the scope, and never
    /// proof of absence.
    public func look(_ query: Query) async throws -> Candidates {
        async let a = Self.attempt(first, query)
        async let b = Self.attempt(second, query)
        return try Candidates.merging(try await a, try await b)
    }

    private static func attempt(_ reader: any Reader, _ query: Query) async throws -> Attempt {
        do {
            return .looked(reader.source, try await reader.look(query))
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
        case .blind(let kind, let error): .blind(kind, String(describing: error))
        }
    }

    var seen: Candidates? { if case .looked(_, let c) = self { c } else { nil } }
}

/// Neither reader of a merged read could look, so there is nothing to answer with. Both
/// errors are kept as thrown, so a caller can still tell a missing grant by its type.
public struct BothBlind: Error, CustomStringConvertible {
    public let first: any Error
    public let second: any Error

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
    /// finds of one reader are never merged with each other.
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
        var duplicates = 0
        for run in b.seen?.found ?? [] {
            var loose: [Word] = []
            let words = run.words
            var i = 0
            while i < words.count {
                let hit = (i..<words.count).reversed().lazy.compactMap { j -> (Int, Int)? in
                    let stretch = Found(first: words[i], rest: Array(words[(i + 1)..<(j + 1)]), source: run.source)
                    return (0..<firsts).first { kept[$0].saysTheSame(as: stretch) }.map { ($0, j) }
                }.first
                guard let (index, end) = hit else {
                    loose.append(words[i])
                    i += 1
                    continue
                }
                if merged.insert(index).inserted {
                    kept[index] = Found(first: kept[index].first, rest: kept[index].rest, source: .merged(kept[index].source, run.source))
                }
                duplicates += 1
                extra += Found(loose, source: run.source)
                loose = []
                i = end + 1
            }
            extra += Found(loose, source: run.source)
        }
        let regions = seen.map(\.region.cgRect)
        let both = regions.dropFirst().reduce(regions[0]) { $0.intersection($1) }
        return Candidates(
            found: (kept + extra).inReadingOrder,
            region: both.isNull ? seen[0].region : ScreenRect(both),
            examined: seen.map(\.examined).reduce(0, +),
            excluded: (seen.flatMap(\.excluded) + [Exclusion(reason: .duplicate, count: duplicates)]).summed,
            reach: a.part.isWhole && b.part.isWhole ? .whole : .stopped(.merged(a.part, b.part))
        )
    }
}

private extension Found {
    /// The same text, forgiving one edit in five characters, at an intersecting place.
    func saysTheSame(as other: Found) -> Bool {
        guard frame.intersects(other.frame) else { return false }
        let a = text.value.filter { !$0.isWhitespace }, b = other.text.value.filter { !$0.isWhitespace }
        return Match.edits(from: a, to: b, anywhere: false) <= max(a.count, b.count) / 5
    }
}

private extension Array where Element == Found {
    static func += (list: inout [Found], found: Found?) {
        if let found { list.append(found) }
    }
}

private extension Found {
    init?(_ words: [Word], source: Source) {
        guard let head = words.first else { return nil }
        self.init(first: head, rest: Array(words.dropFirst()), source: source)
    }
}

private extension Array where Element == Exclusion {
    /// One entry per reason, in the order reasons first appear, with no zero counts.
    var summed: [Exclusion] {
        var order: [Exclusion.Reason] = []
        var counts: [Exclusion.Reason: Int] = [:]
        for e in self where e.count > 0 {
            if counts[e.reason] == nil { order.append(e.reason) }
            counts[e.reason, default: 0] += e.count
        }
        return order.map { Exclusion(reason: $0, count: counts[$0]!) }
    }
}
