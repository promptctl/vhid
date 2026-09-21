import CoreGraphics
import Testing
@testable import Eyes

/// What a reading can honestly claim, asked with no reader behind it.
///
/// The distinction every test here turns on is absence against blindness. A caller told
/// "nothing matched" acts on it; a caller told that by a reader which saw nothing acts on
/// a lie. [LAW:no-silent-failure]
@Suite struct ReadingTests {
    static let region = ScreenRect(x: 0, y: 0, width: 1512, height: 982)

    private func reading(outcome: Outcome, examined: Int, reach: Reach) -> Reading {
        Reading(outcome: outcome, scope: Scope(region: Self.region, examined: examined, reach: reach))
    }

    private func found(_ text: String) -> Found {
        Found(
            text: Text(text)!,
            frame: ScreenRect(x: 10, y: 20, width: 30, height: 40),
            source: .pixels(confidence: Confidence(0.9)!)
        )
    }

    /// The whole point: a reader that got through the region and examined something, and
    /// matched nothing, has established that the text is not on the screen.
    @Test func nothingFoundAcrossAWholeReadProvesTheTextIsNotThere() {
        let read = reading(outcome: .nearest([]), examined: 143, reach: .whole)
        #expect(read.provesAbsence)
    }

    /// A blank region is the most useful question anyone asks this package - *is the
    /// dialog gone?* - and it examines nothing, because there is nothing in it to examine.
    /// An earlier rule also required `examined > 0`, which refused exactly the reading
    /// that most certainly proves an absence.
    ///
    /// Blindness is not what this number is for. `Reader.read` throws when it could not
    /// see, so a `Reading` that exists at all came from a reader that looked, and asking
    /// again here was a second enforcer of an invariant the boundary already holds.
    /// [LAW:single-enforcer]
    @Test func aWholeReadOfABlankRegionProvesTheAbsence() {
        let read = reading(outcome: .nearest([]), examined: 0, reach: .whole)
        #expect(read.provesAbsence)
    }

    /// A walk that hit its element cap has not seen the region, so its silence about a
    /// string says nothing about whether the string is there.
    @Test func aReadThatStoppedShortProvesNothing() {
        for stop in [Stop.elementLimit(2000), .timeBudget(.seconds(5)), .resultLimit(.default)] {
            let read = reading(outcome: .nearest([]), examined: 2000, reach: .stopped(stop))
            #expect(!read.provesAbsence, "a read stopped by \(stop) cannot prove an absence")
        }
    }

    /// A reading that matched is not an absence, whatever else its scope says.
    @Test func aReadingThatMatchedIsNotAnAbsence() {
        let read = reading(outcome: .matched(Matches([found("Allow")])!), examined: 143, reach: .whole)
        #expect(!read.provesAbsence)
    }

    /// Near misses travel on the failing arm, so a caller cannot read one as a match. The
    /// distance is the fact that separates a recogniser slipping from a different word
    /// being on the screen.
    @Test func nearMissesTravelWithTheirDistanceAndNotAsMatches() {
        let read = reading(
            outcome: .nearest([
                Near(found: found("AlIow"), distance: 1),
                Near(found: found("Cancel"), distance: 6),
            ]),
            examined: 47,
            reach: .whole
        )
        guard case .nearest(let near) = read.outcome else {
            Issue.record("a reading with no match is not carrying matches")
            return
        }
        #expect(near.first?.distance == 1)
        // Still an absence: the nearest thing being one edit away does not make it a hit.
        #expect(read.provesAbsence)
    }

    /// [LAW:parse-dont-validate] The empty string is not a finding. The accessibility tree
    /// answers it for every element holding no text, and a reading full of those would be
    /// rows saying nothing at a coordinate.
    @Test func textWithNothingInItIsNotAFinding() {
        #expect(Text("") == nil)
        #expect(Text("Allow")?.value == "Allow")
    }

    /// A row of blank space says nothing at a coordinate just as loudly as the empty
    /// string does, and the tree answers it about as often - spacers, blank labels, a cell
    /// holding one space. A `Match.contains(" ")` against a reading full of those would
    /// match every one of them.
    @Test func aRowOfBlankSpaceIsNotAFindingEither() {
        #expect(Text(" ") == nil)
        #expect(Text("\n") == nil)
        #expect(Text("\t \n") == nil)
    }

    /// Blank space *around* text is kept. Trimming would be this type editing the screen
    /// rather than describing it, and the coordinate belongs to the run as it was read.
    @Test func blankSpaceAroundRealTextIsKept() {
        #expect(Text(" OK ")?.value == " OK ")
    }

    /// A role exists exactly when the tree found it. There is no spelling of a recognised
    /// run that carries a role, or a tree element that carries a confidence.
    @Test func onlyTheTreeNamesARole() {
        #expect(Source.tree(role: Role(rawValue: "AXButton")).kind == .tree)
        #expect(Source.pixels(confidence: Confidence(0.5)!).kind == .pixels)
    }

    /// A recogniser reporting slightly over 1 is not a reading to throw away. Infinities
    /// clamp the same way, for the same reason.
    @Test func confidenceIsClampedRatherThanRefused() {
        #expect(Confidence(1.0000001)?.value == 1)
        #expect(Confidence(-0.2)?.value == 0)
        #expect(Confidence(.infinity)?.value == 1)
        #expect(Confidence(-.infinity)?.value == 0)
        #expect(Confidence(0.5)! < Confidence(0.9)!)
    }

    /// NaN is the one value refused, because clamping does not touch it: `max(.nan, 0)` is
    /// NaN and so is the `min` after it. A `Confidence` holding NaN is unequal to itself,
    /// which silently breaks every conformance built on it - a `Found` carrying one never
    /// dedupes in a `Set`, and a page of findings sorted by confidence comes back
    /// unsorted with no trap to notice. [LAW:types-are-the-program]
    @Test func confidenceRefusesNaNBecauseClampingCannotCatchIt() {
        #expect(Confidence(.nan) == nil)
        // The behaviour that made it worth refusing, stated so it cannot quietly return.
        #expect(min(max(Double.nan, 0), 1).isNaN)
    }

    /// [LAW:parse-dont-validate] `matched` cannot carry an empty list, so it cannot mean
    /// "nothing matched" in the arm whose whole purpose is that the *other* arm means it.
    /// A reader with nothing to report has one way to say so.
    @Test func aMatchThatMatchedNothingCannotBeSpelled() {
        #expect(Matches([]) == nil)
        #expect(Matches([found("Allow")])?.count == 1)
        #expect(Matches([found("Allow"), found("Deny")])?.all.map(\.text.value) == ["Allow", "Deny"])
    }

    /// The reason the arm matters: `provesAbsence` reads the arm and not a count, so an
    /// empty `matched` would be a whole read that established an absence and could not
    /// say so.
    @Test func aWholeReadThatMatchedNothingProvesTheAbsenceItEstablished() {
        #expect(reading(outcome: .nearest([]), examined: 200, reach: .whole).provesAbsence)
    }

    /// [LAW:types-are-the-program] A limit of zero returns nothing beside a scope
    /// reporting a whole read, which reads exactly like an absence; a negative one traps
    /// the moment a reader caps with `prefix`. Neither is spellable.
    @Test func aQueryCannotBeSpelledToAskForNothing() {
        #expect(Limit(0) == nil)
        #expect(Limit(-1) == nil)
        #expect(Limit(1)?.count == 1)
        #expect(Limit.default.count == 50)
        #expect(Query(match: .exact("Allow"), region: .display(0)).limit == .default)
    }

    /// [LAW:types-are-the-program] A tolerance below zero cannot be satisfied by any
    /// string, so a reader that walks a whole region with the text plainly on it matches
    /// nothing and reports `reach == .whole` - which is `provesAbsence` answering true
    /// for text that is on the screen. The same hole `Limit` closed, in the same file.
    @Test func aToleranceThatNoStringCouldSatisfyCannotBeSpelled() {
        #expect(Edits(-1) == nil)
        #expect(Edits(0)?.count == 0)
        #expect(Edits(2)?.count == 2)
        #expect(Match.within(edits: Edits(1)!, of: "Allow") == .within(edits: Edits(1)!, of: "Allow"))
    }

    /// A display is named by the id the window server knows it by, not by a position in a
    /// list. Indexes move when a monitor sleeps, wakes or is rearranged, and a caller that
    /// resolved "the second display" would silently read a different monitor and report a
    /// whole-region absence about it. [FRAMING:representation]
    @Test func aDisplayIsNamedByItsIdAndNotItsPlaceInALine() {
        let main: CGDirectDisplayID = CGMainDisplayID()
        #expect(Region.display(main) == Region.display(main))
        #expect(Region.display(main) != Region.display(main &+ 1))
    }
}
