import Foundation

/// What a reader was asked for.
///
/// Every query is bounded by construction. `region` names somewhere on screen and
/// `limit` caps what comes back, so there is no spelling of this type that means "all
/// the text on every display, unbounded" - not because a reader refuses it, but because
/// the words for it do not exist. Widening is a caller's to do, one region at a time,
/// deliberately. [LAW:types-are-the-program]
public struct Query: Sendable, Hashable {
    /// What to look for. Absent asks for everything in the region, which the region and
    /// the limit still bound.
    public let match: Match?
    public let region: Region
    /// The most findings to return. A reading that hit this says so in its scope, so the
    /// cap can never be mistaken for the whole answer. [LAW:no-silent-failure]
    public let limit: Int

    public init(match: Match?, region: Region, limit: Int = 50) {
        self.match = match
        self.region = region
        self.limit = limit
    }
}

/// How text is compared.
///
/// Comparison is case-insensitive throughout and there is no flag to make it otherwise.
/// A recogniser reading pixels has no reliable idea of case - a small-caps button label
/// and a styled heading both come back in whatever the glyphs looked like - so a
/// case-sensitive match would fail for a reason that has nothing to do with the screen.
/// [LAW:no-mode-explosion]
public enum Match: Sendable, Hashable {
    case exact(String)
    case contains(String)
    /// Within this many single-character edits, for text a recogniser may have slipped on.
    case within(edits: Int, of: String)
}

/// Where on screen to look.
///
/// There is no case meaning "everywhere". A caller that means every display asks for each
/// one, which is a thing to do on purpose rather than a default that quietly reads a wall
/// of monitors. [LAW:dataflow-not-control-flow]
public enum Region: Sendable, Hashable {
    case rect(ScreenRect)
    /// One display, by its index in the geometry reading.
    case display(Int)
    /// One window's bounds, by the id the geometry reading gave it.
    case window(UInt32)
}

/// What a reader found, and what it can honestly say about having looked.
public struct Reading: Sendable, Hashable {
    public let outcome: Outcome
    public let scope: Scope

    public init(outcome: Outcome, scope: Scope) {
        self.outcome = outcome
        self.scope = scope
    }
}

/// [LAW:types-are-the-program] Two shapes, not one list plus a flag. A reading either
/// carries what matched or carries what was closest to matching, and the two cannot both
/// be populated, so no caller reaches for `isEmpty` and then wonders what the other field
/// means. The `nearest` arm is what the reader already holds the moment a query fails: it
/// has just read the screen, so the closest handful costs a handful of rows and is
/// computed where the data already sits rather than by shipping the data out.
public enum Outcome: Sendable, Hashable {
    /// What matched, in reading order. Everything in the region when the query named
    /// nothing to match.
    case matched([Found])
    /// Nothing matched. What was closest, nearest first.
    case nearest([Near])
}

/// Something on screen that did not match, and how far off it was.
///
/// The distance is what tells a slip apart from a different word. One edit from what was
/// asked for is a recogniser reading a capital I as a lowercase l; six edits away, across
/// a screen that was fully read, is the thing not being there.
public struct Near: Sendable, Hashable {
    public let found: Found
    /// Single-character edits between this text and what was asked for.
    public let distance: Int

    public init(found: Found, distance: Int) {
        self.found = found
        self.distance = distance
    }
}

/// What was actually looked at, which is what makes a reading with no match worth
/// anything at all.
///
/// [LAW:no-silent-failure] An empty answer on its own collapses two facts a caller has to
/// tell apart: the text is not on the screen, and the reader could not see. One of those
/// ends a search and the other means the tool is broken, and a caller handed the same
/// value for both guesses.
public struct Scope: Sendable, Hashable {
    /// The rectangle that was searched, resolved from the query's region.
    public let region: ScreenRect
    /// How many candidates the reader examined inside it - runs recognised, or elements
    /// walked. Zero is not an empty screen; zero is a reader that read nothing.
    public let examined: Int
    /// How many were dropped before matching, and why, so a narrow answer says what it
    /// narrowed. A reading that filtered 200 table cells away and says so is trustworthy;
    /// the same reading silent about them is a false negative nobody can detect.
    public let excluded: [Exclusion]
    public let reach: Reach

    public init(region: ScreenRect, examined: Int, excluded: [Exclusion] = [], reach: Reach) {
        self.region = region
        self.examined = examined
        self.excluded = excluded
        self.reach = reach
    }
}

/// Some candidates left out, named by why.
public struct Exclusion: Sendable, Hashable {
    public let reason: Reason
    public let count: Int

    public init(reason: Reason, count: Int) {
        self.reason = reason
        self.count = count
    }

    public enum Reason: String, Sendable, Hashable {
        /// No text on it at all.
        case wordless
        /// Zero-sized, offscreen, or outside the region asked for.
        case unplaced
        /// The same text at the same place, already reported once. The accessibility tree
        /// produces these constantly - a cell and its own label are two elements.
        case duplicate
        /// Ranked below what the limit allowed through.
        case ranked
    }
}

/// Whether the reader got through the region, or stopped short of it.
public enum Reach: Sendable, Hashable {
    /// Everything in the region was examined. Only this one makes an absence a fact
    /// about the screen rather than a fact about the read.
    case whole
    case stopped(Stop)
}

public enum Stop: Sendable, Hashable {
    /// Hit the cap on elements one walk may read.
    case elementLimit(Int)
    /// Ran out of the time one read is given.
    case timeBudget(Duration)
    /// More matched than the query's limit allowed back.
    case resultLimit(Int)
}

public extension Reading {
    /// Whether "it is not there" is a fact about the screen rather than about the read.
    ///
    /// [LAW:single-enforcer] Derived in the one place, because the three conditions are
    /// easy to get right and easy to forget: nothing matched, the reader got through the
    /// whole region, and it actually examined something. A caller re-deriving this will
    /// eventually check only the first.
    var provesAbsence: Bool {
        guard case .nearest = outcome else { return false }
        return scope.reach == .whole && scope.examined > 0
    }
}
