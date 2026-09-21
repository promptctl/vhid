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
            source: .pixels(confidence: Confidence(0.9))
        )
    }

    /// The whole point: a reader that got through the region and examined something, and
    /// matched nothing, has established that the text is not on the screen.
    @Test func nothingFoundAcrossAWholeReadProvesTheTextIsNotThere() {
        let read = reading(outcome: .nearest([]), examined: 143, reach: .whole)
        #expect(read.provesAbsence)
    }

    /// The case that reads identically to the one above unless the count is carried. A
    /// capture that wrote no file, or a grant that was never given, leaves a reader with
    /// nothing to match against - and "I matched nothing" is true and useless.
    @Test func aReadThatExaminedNothingProvesNothing() {
        let read = reading(outcome: .nearest([]), examined: 0, reach: .whole)
        #expect(!read.provesAbsence)
    }

    /// A walk that hit its element cap has not seen the region, so its silence about a
    /// string says nothing about whether the string is there.
    @Test func aReadThatStoppedShortProvesNothing() {
        for stop in [Stop.elementLimit(2000), .timeBudget(.seconds(5)), .resultLimit(50)] {
            let read = reading(outcome: .nearest([]), examined: 2000, reach: .stopped(stop))
            #expect(!read.provesAbsence, "a read stopped by \(stop) cannot prove an absence")
        }
    }

    /// A reading that matched is not an absence, whatever else its scope says.
    @Test func aReadingThatMatchedIsNotAnAbsence() {
        let read = reading(outcome: .matched([found("Allow")]), examined: 143, reach: .whole)
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

    /// A role exists exactly when the tree found it. There is no spelling of a recognised
    /// run that carries a role, or a tree element that carries a confidence.
    @Test func onlyTheTreeNamesARole() {
        #expect(Source.tree(role: Role(rawValue: "AXButton")).kind == .tree)
        #expect(Source.pixels(confidence: Confidence(0.5)).kind == .pixels)
    }

    /// A recogniser reporting slightly over 1 is not a reading to throw away.
    @Test func confidenceIsClampedRatherThanRefused() {
        #expect(Confidence(1.0000001).value == 1)
        #expect(Confidence(-0.2).value == 0)
        #expect(Confidence(0.5) < Confidence(0.9))
    }
}
