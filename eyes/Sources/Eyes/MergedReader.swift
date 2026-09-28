/// Two readers asked the same query, their answers reconciled into one.
///
/// It holds each as `any Reader` and nothing more, so neither the readers nor this type
/// knows which kinds it holds - the tree and the pixels compose here without either
/// linking the other, and two of anything compose the same way. [LAW:composability]
/// The order is a priority: where both found the same thing, the first reader's words and
/// frame are the ones kept.
public struct MergedReader: Reader {
    public let source = SourceKind.merged
    let first: any Reader
    let second: any Reader

    public init(_ first: any Reader, _ second: any Reader) {
        self.first = first
        self.second = second
    }

    /// Asks both, one after the other: readers are main-actor, so there is nothing to
    /// overlap. Throws only when neither could look - one reader that could not is part
    /// of the answer, carried in the scope, and never proof of absence.
    public func read(_ query: Query) async throws -> Reading {
        let a = await Self.attempt(first, query)
        let b = await Self.attempt(second, query)
        return try Reading.merging(a, b, query: query)
    }

    private static func attempt(_ reader: any Reader, _ query: Query) async -> Attempt {
        do {
            return .read(reader.source, try await reader.read(query))
        } catch {
            return .blind(reader.source, error)
        }
    }
}

/// One reader's answer to a merged query: a reading, or the reason it could not look.
public enum Attempt: Sendable {
    case read(SourceKind, Reading)
    case blind(SourceKind, any Error)

    var part: Part {
        switch self {
        case .read(let kind, let reading): .read(kind, reading.scope.reach)
        case .blind(let kind, let error): .blind(kind, String(describing: error))
        }
    }

    var reading: Reading? { if case .read(_, let r) = self { r } else { nil } }
}

/// Neither reader of a merged read could look, so there is no reading to return.
public struct BothBlind: Error, CustomStringConvertible {
    public let first: any Error
    public let second: any Error

    public var description: String { "neither reader could look: \(first); \(second)" }
}

public extension Reading {
    /// Two readers' answers to one query as one reading.
    ///
    /// The same text (compared as `Match` compares, ignoring case) at intersecting frames
    /// is one thing on screen: the first reader's copy is kept, its source becomes
    /// `.merged` of both, and the second's is counted as a `duplicate` exclusion. The
    /// same text elsewhere is a second thing and stays. The union is then judged again
    /// by `judging`, so the query's match and limit mean what they mean for one reader.
    /// [LAW:single-enforcer]
    ///
    /// The reach is whole only when both readers read the region whole. Otherwise it
    /// names each reader's reach, and a reader that threw is named blind - so the other's
    /// empty answer never proves an absence over a region half of the merge did not see.
    /// [LAW:no-silent-failure] Pure, so every rule is tested with readings a test wrote.
    /// [LAW:effects-at-boundaries]
    static func merging(_ a: Attempt, _ b: Attempt, query: Query) throws -> Reading {
        if case .blind(_, let e1) = a, case .blind(_, let e2) = b { throw BothBlind(first: e1, second: e2) }
        let readings = [a.reading, b.reading].compactMap { $0 }
        var kept = a.reading?.outcome.found ?? []
        var duplicates = 0
        for found in b.reading?.outcome.found ?? [] {
            if let i = kept.firstIndex(where: { $0.isSameThing(as: found) }) {
                kept[i] = kept[i].merged(with: found)
                duplicates += 1
            } else {
                kept.append(found)
            }
        }
        let bothWhole = a.part.isWhole && b.part.isWhole
        return judging(
            kept.inReadingOrder,
            query: query,
            region: readings[0].scope.region,
            examined: readings.map(\.scope.examined).reduce(0, +),
            excluded: (readings.flatMap(\.scope.excluded) + [Exclusion(reason: .duplicate, count: duplicates)]).summed,
            reach: bothWhole ? .whole : .stopped(.merged(a.part, b.part))
        )
    }
}

private extension Outcome {
    /// Everything the reading holds, matched or near, for judging again.
    var found: [Found] {
        switch self {
        case .matched(let m): m.all
        case .nearest(let near): near.map(\.found)
        }
    }
}

private extension Found {
    func isSameThing(as other: Found) -> Bool {
        text.value.lowercased() == other.text.value.lowercased() && frame.cgRect.intersects(other.frame.cgRect)
    }

    func merged(with other: Found) -> Found {
        Found(first: first, rest: rest, source: .merged(source, other.source))
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
