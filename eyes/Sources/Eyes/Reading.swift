import CoreGraphics
import Foundation

/// The most findings one reading may return, which is always at least one.
///
/// [LAW:types-are-the-program] A bare `Int` admitted zero and negatives, which `Query`'s
/// own documentation says cannot happen. Both are the false absence the rest of this file
/// is built to prevent: a reader capping at zero returns nothing beside a scope reporting
/// a whole read, which reads exactly like "the text is not on screen", and a reader
/// implementing the cap the obvious way traps outright on a negative - `prefix` refuses a
/// negative length. Neither is spellable now.
public struct Limit: Sendable, Hashable {
    public let count: Int

    /// Enough for any reading a caller means to look at, and few enough that a runaway
    /// walk is capped rather than shipped.
    public static let `default` = Limit(unchecked: 50)

    private init(unchecked count: Int) {
        self.count = count
    }

    public init?(_ count: Int) {
        guard count >= 1 else { return nil }
        self.count = count
    }
}

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
    public let limit: Limit

    public init(match: Match?, region: Region, limit: Limit = .default) {
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
    case within(edits: Edits, of: String)
}

/// A number of single-character edits, which is never negative.
///
/// [LAW:types-are-the-program] The same hole `Limit` closed, in the same file. A negative
/// tolerance cannot be satisfied by any string, so a reader that walks a whole region
/// with the text plainly on it matches nothing, returns `.nearest`, and reports
/// `reach == .whole` - which is `provesAbsence` answering true for text that is on the
/// screen. A query that cannot match is not a query a caller can mean.
public struct Edits: Sendable, Hashable {
    public let count: Int

    /// Zero is allowed and means exactly what it says: no slip tolerated.
    public init?(_ count: Int) {
        guard count >= 0 else { return nil }
        self.count = count
    }
}

/// Where on screen to look.
///
/// There is no case meaning "everywhere". A caller that means every display asks for each
/// one, which is a thing to do on purpose rather than a default that quietly reads a wall
/// of monitors. [LAW:dataflow-not-control-flow]
public enum Region: Sendable, Hashable {
    case rect(ScreenRect)
    /// One display, by the id the window server knows it by.
    ///
    /// An id and not an index. A position in a list is a name that moves: displays
    /// reorder when a monitor sleeps, wakes, disconnects or is rearranged, so a caller
    /// that resolved "the second display" and read it a moment later would be reading a
    /// different monitor and reporting a whole-region absence about it. The id survives
    /// all of that, which is why the case below names windows the same way.
    /// [FRAMING:representation]
    case display(CGDirectDisplayID)
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

/// One or more findings, in reading order.
///
/// [LAW:parse-dont-validate] This exists so `Outcome.matched` cannot carry an empty list.
/// An empty `matched` would mean "nothing matched" a second time, in the arm whose whole
/// purpose is that the other arm means it - and the two would not agree, because
/// `provesAbsence` reads the arm and not the count, so a whole read that matched nothing
/// could not prove the absence it had actually established.
public struct Matches: Sendable, Hashable {
    public let first: Found
    public let rest: [Found]

    public init?(_ found: [Found]) {
        guard let head = found.first else { return nil }
        self.first = head
        self.rest = Array(found.dropFirst())
    }

    /// All of them, derived rather than stored so it cannot disagree with the two fields
    /// it is built from. [LAW:one-source-of-truth]
    public var all: [Found] { [first] + rest }
    public var count: Int { rest.count + 1 }
}

/// [LAW:types-are-the-program] Two shapes, not one list plus a flag. A reading either
/// carries what matched or carries what was closest to matching, and the two cannot both
/// be populated, so no caller reaches for `isEmpty` and then wonders what the other field
/// means. The `nearest` arm is what the reader already holds the moment a query fails: it
/// has just read the screen, so the closest handful costs a handful of rows and is
/// computed where the data already sits rather than by shipping the data out.
public enum Outcome: Sendable, Hashable {
    /// What matched, in reading order. Everything in the region when the query named
    /// nothing to match. Never empty - that is what `nearest` is for.
    case matched(Matches)
    /// Nothing matched. What was closest, nearest first, which is empty when nothing on
    /// screen was close enough to be worth reporting.
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
    /// walked.
    ///
    /// Zero is a blank region, not a blind reader. Blindness never arrives as a returned
    /// `Reading` at all: `Reader.read` throws when it could not see - no grant, no such
    /// display, a capture that wrote nothing - so a `Reading` in hand is by contract from
    /// a reader that looked. This number is what the caller was told about the looking,
    /// not a second place blindness is decided. [LAW:single-enforcer]
    ///
    /// A plain `Int` where `limit` is a `Limit`, and the difference is the point rather
    /// than an oversight: a limit is an input that *drives* behaviour, so a bad one
    /// changes what the reader does and is worth making unspellable. This is an
    /// observation the reader *reports*, and a refinement type would buy only the sign -
    /// it cannot stop a reader that examined three elements from saying five, which is
    /// the only way this field is ever wrong in practice. Constraining it would look like
    /// a guarantee while providing none.
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
    /// Hit the cap on elements one walk may read. A `Limit` and not an `Int` for the same
    /// reason the query's is: a cap of zero or less is not a cap anyone set.
    case elementLimit(Limit)
    /// Ran out of the time one read is given.
    case timeBudget(Duration)
    /// More matched than the query's limit allowed back. It carries the query's own
    /// `Limit` rather than a loose `Int`, so the cap that was hit and the cap that was
    /// asked for are one value. [LAW:one-source-of-truth]
    case resultLimit(Limit)
}

public extension Reading {
    /// Whether "it is not there" is a fact about the screen rather than about the read.
    ///
    /// [LAW:single-enforcer] Derived in the one place, because the two conditions are easy
    /// to get right and easy to forget: nothing matched, and the reader got through the
    /// whole region. A caller re-deriving this will eventually check only the first.
    ///
    /// It deliberately does not also require that something was examined. That third
    /// condition was here to catch a blind reader, and it caught the wrong thing: a
    /// region that is genuinely blank - a dialog that has closed, which is the single
    /// most useful question anyone asks this package - has nothing in it to examine, so
    /// the reading that most certainly proves an absence reported zero and was refused.
    /// Blindness has an owner already, one layer up: `Reader.read` throws when it could
    /// not see, so a `Reading` that exists at all came from a reader that looked. Asking
    /// again here was a second enforcer of an invariant the boundary already holds, and
    /// the two disagreed exactly where it mattered.
    var provesAbsence: Bool {
        guard case .nearest = outcome else { return false }
        return scope.reach == .whole
    }
}
