/// Which way a wait expects the query's outcome to go.
public enum Until: String, Sendable, Hashable, CaseIterable {
    /// Something matched.
    case present
    /// Nothing matched, across a region read whole.
    case absent

    /// Whether one reading shows it. Absent is `provesAbsence` and not "nothing matched":
    /// a read that stopped short, or a merge one of whose readers went blind, has not seen
    /// the region and cannot say the text left it. [LAW:single-enforcer]
    func holds(in reading: Reading) -> Bool {
        switch self {
        case .present: if case .matched = reading.outcome { true } else { false }
        case .absent: reading.provesAbsence
        }
    }

    /// How many readings in a row must show it before the wait believes it. A capture
    /// cannot invent the text asked for, so one match is a match. A capture can lose it -
    /// one bad frame among many reads is the likeliest false "gone" - so an absence has to
    /// be read twice running. [LAW:types-are-the-program]
    var readsInARow: Int {
        switch self {
        case .present: 1
        case .absent: 2
        }
    }
}

/// What to wait for and for how long. The timeout is positive and finite by construction.
public struct Wait: Sendable, Hashable {
    public let until: Until
    public let timeout: Duration

    /// The longest a wait may take: long enough for any dialog, short enough that a wait
    /// on text that never comes cannot hold an MCP call open indefinitely.
    public static let longest: Double = 600

    /// The timeout when a caller names none.
    public static let defaultSeconds: Double = 10

    /// Refuses a timeout that is not a number of seconds between zero and `longest`.
    /// [LAW:parse-dont-validate]
    public init?(until: Until, seconds: Double) {
        guard seconds.isFinite, seconds > 0, seconds <= Self.longest else { return nil }
        self.until = until
        self.timeout = .milliseconds(Int64((seconds * 1000).rounded(.up)))
    }
}

/// How a wait ended: the last reading, and what it took to get there.
public struct Waited: Sendable, Hashable {
    /// The final reading, reported as any other: a timeout still carries its nearest
    /// candidates.
    public let reading: Reading
    public let reads: Int
    public let took: Duration
    /// Whether the outcome went the way the wait expected, rather than the time running out.
    public let settled: Bool
}

/// A wait for an absence that one of a merge's readers could not look for.
/// A `ReaderError`, so a missing grant is told apart here as for any reader that could
/// not look - a server names the app that must hold it. [LAW:single-enforcer]
public struct WaitBlind: ReaderError, CustomStringConvertible {
    public let part: Part

    public var missingGrant: Bool {
        if case .blind(_, _, let grant) = part { grant } else { false }
    }

    public var description: String {
        guard case .blind(let kind, let why, _) = part else { return "\(part)" }
        return "\(kind.rawValue) could not look, so an absence cannot be proven: \(why)"
    }
}

extension Reach {
    /// The first reader of a merge that could not look, if one could not.
    var blindPart: Part? {
        guard case .stopped(.merged(let a, let b)) = self else { return nil }
        return [a, b].first(where: \.isBlind)
    }
}

/// The pause between reads. Short, because the read is the cost: measured on studious, one
/// tree read of a whole display took about 0.9 s with process start. The gap only keeps a
/// fast read - a small window, a blank region - from spinning.
public let waitInterval: Duration = .milliseconds(100)

/// Reads until the outcome goes the way `wait` expects or its timeout passes, and returns
/// once. It reports; it retries no action. A read that throws ends the wait with that
/// error: a reader that could not look has not seen the text go. [LAW:no-silent-failure]
///
/// Every read after the first asks the same question of the region the first one
/// resolved, as `Region.pinned` holds it. Each read is judged and its boxes left unchecked:
/// whether text is there does not turn on them, and only the reading the wait ends on is
/// printed, so only its boxes are checked - after the deadline is weighed, by at most the
/// time a reader allows its checks.
///
/// Over a read and not a `Reader`, so any reader - or a server's serialised one - waits
/// the same way. [LAW:composability]
public func waiting(
    for wait: Wait, on query: Query, every interval: Duration = waitInterval, read: (Query) async throws -> Judged
) async throws -> Waited {
    let clock = ContinuousClock()
    let start = clock.now
    var reads = 0
    var inARow = 0
    var asked = query
    while true {
        let began = clock.now
        let judged = try await read(asked)
        let reading = judged.reading
        reads += 1
        asked = query.on(query.region.pinned(to: reading.scope.region))
        // A merge one of whose readers could not look can never read the region whole,
        // so an absence it waits for would only ever time out: that reader's error ends
        // the wait instead. [LAW:no-silent-failure]
        if wait.until == .absent, let blind = reading.scope.reach.blindPart {
            throw WaitBlind(part: blind)
        }
        inARow = wait.until.holds(in: reading) ? inARow + 1 : 0
        let settled = inARow >= wait.until.readsInARow
        // The next read, taking as long as this one did, would end past the deadline: this
        // reading is the answer. Measured on studious, a whole-display read is most of a
        // second, so counting only the pause overshot a 2 s timeout by 0.6 s.
        if settled || clock.now + interval + (clock.now - began) - start > wait.timeout {
            return Waited(reading: try await judged.pressed(), reads: reads, took: clock.now - start, settled: settled)
        }
        try await Task.sleep(for: interval)
    }
}
