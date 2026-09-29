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

/// The pause between reads. Short, because the read is the cost: measured on studious, one
/// tree read of a whole display took about 0.9 s with process start. The gap only keeps a
/// fast read - a small window, a blank region - from spinning.
public let waitInterval: Duration = .milliseconds(100)

/// Reads until the outcome goes the way `wait` expects or its timeout passes, and returns
/// once. It reports; it retries no action. A read that throws ends the wait with that
/// error: a reader that could not look has not seen the text go. [LAW:no-silent-failure]
///
/// Every read after the first looks at the rectangle the first one resolved, so the wait
/// re-reads the same place: a window that closes is its region with the text gone, not a
/// window that can no longer be found. Measured on studious, waiting on a dialog by its
/// window id threw "no on-screen window" the moment the dialog closed.
///
/// Over a read and not a `Reader`, so any reader - or a server's serialised one - waits
/// the same way. [LAW:composability]
public func waiting(
    for wait: Wait, on query: Query, every interval: Duration = waitInterval, read: (Query) async throws -> Reading
) async throws -> Waited {
    let clock = ContinuousClock()
    let start = clock.now
    var reads = 0
    var inARow = 0
    var asked = query
    while true {
        let began = clock.now
        let reading = try await read(asked)
        asked = Query(match: query.match, region: .rect(reading.scope.region), limit: query.limit)
        reads += 1
        inARow = wait.until.holds(in: reading) ? inARow + 1 : 0
        let settled = inARow >= wait.until.readsInARow
        // The next read, taking as long as this one did, would end past the deadline: this
        // reading is the answer. Measured on studious, a whole-display read is most of a
        // second, so counting only the pause overshot a 2 s timeout by 0.6 s.
        if settled || clock.now + interval + (clock.now - began) - start > wait.timeout {
            return Waited(reading: reading, reads: reads, took: clock.now - start, settled: settled)
        }
        try await Task.sleep(for: interval)
    }
}
