import Testing
@testable import Eyes

/// What a reader's candidates become, asked with a list a test wrote.
@Suite struct JudgeTests {
    static let region = ScreenRect(x: 0, y: 0, width: 1512, height: 982)

    /// A run as a reader places it: each word at its own spot along one line.
    private func found(_ text: String, y: Double = 0) -> Found {
        let words = text.split(separator: " ").enumerated().map { i, w in
            Word(text: Text(String(w))!, frame: ScreenRect(x: 10 + Double(i) * 40, y: y, width: 30, height: 12))
        }
        return Found(first: words[0], rest: Array(words.dropFirst()), source: .pixels(confidence: Confidence(0.9)!))
    }

    private func judge(_ texts: [String], _ match: Match?, limit: Limit = .default) -> Reading {
        Reading.judging(
            texts.enumerated().map { found($1, y: Double($0) * 20) },
            query: Query(match: match, region: .rect(Self.region), limit: limit),
            region: Self.region,
            examined: texts.count,
            excluded: [],
            reach: .whole
        )
    }

    @Test func containsFindsTheQueryInsideALongerRunIgnoringCase() {
        let read = judge(["File", "Save As…", "Close"], .contains("save"))
        guard case .matched(let matches) = read.outcome else { Issue.record("\(read)"); return }
        #expect(matches.all.map(\.text.value) == ["Save"])
        #expect(read.scope.reach == .whole)
    }

    @Test func exactRefusesARunThatOnlyContainsTheQuery() {
        guard case .nearest(let near) = judge(["Save As…"], .exact("Save")).outcome else {
            Issue.record("matched"); return
        }
        #expect(near.map(\.distance) == [4])
    }

    /// The case the nearest rows exist for: a capital I read as a lowercase l is one edit
    /// away, and a caller seeing distance 1 knows to widen rather than give up.
    @Test func aMisreadComesBackOneEditAwayAheadOfUnrelatedText() {
        let read = judge(["Terminal", "Setlings", "Help"], .contains("Settings"))
        guard case .nearest(let near) = read.outcome else { Issue.record("matched"); return }
        #expect(near.first?.found.text.value == "Setlings")
        #expect(near.first?.distance == 1)
        #expect(read.provesAbsence)
    }

    @Test func withinToleratesTheEditsItWasGiven() {
        guard case .matched = judge(["Setlings"], .within(edits: Edits(1)!, of: "Settings")).outcome else {
            Issue.record("did not match"); return
        }
    }

    @Test func theNearestAreCappedToAHandful() {
        guard case .nearest(let near) = judge((1...40).map { "run \($0)" }, .exact("absent")).outcome else {
            Issue.record("matched"); return
        }
        #expect(near.count == Reading.nearestShown)
    }

    /// Asking for nothing in particular is reading the region: everything matches.
    @Test func noMatchReturnsEverythingInReadingOrder() {
        guard case .matched(let matches) = judge(["a", "b", "c"], nil).outcome else {
            Issue.record("nothing"); return
        }
        #expect(matches.all.map(\.text.value) == ["a", "b", "c"])
    }

    /// A cap that cut matches says so twice over: the reach stops short, so the reading
    /// proves nothing about what was cut, and the exclusion says how many.
    @Test func aLimitThatCutMatchesDeclaresIt() {
        let read = judge(["ok 1", "ok 2", "ok 3"], .contains("ok"), limit: Limit(2)!)
        guard case .matched(let matches) = read.outcome else { Issue.record("nothing"); return }
        #expect(matches.count == 2)
        #expect(read.scope.reach == .stopped(.resultLimit(Limit(2)!)))
        #expect(read.scope.excluded == [Exclusion(reason: .ranked, count: 1)])
    }

    @Test func aBlankRegionProvesAbsenceWithNoNearest() {
        let read = judge([], .contains("Cancel"))
        #expect(read.outcome == .nearest([]))
        #expect(read.provesAbsence)
    }

    /// Vision reads a row of menus as one run, and the centre of that run is on none of
    /// them. A `contains` match lands on the words that matched, not the run around them.
    @Test func aContainsMatchPointsAtTheWordsThatMatched() {
        let words = ["Shell", "Edit", "View"].enumerated().map { i, w in
            Word(text: Text(w)!, frame: ScreenRect(x: Double(i) * 50, y: 0, width: 40, height: 20))
        }
        let run = Found(first: words[0], rest: Array(words.dropFirst()), source: .pixels(confidence: Confidence(1)!))
        let read = Reading.judging([run], query: Query(match: .contains("edit"), region: .rect(Self.region)),
                                   region: Self.region, examined: 1, excluded: [], reach: .whole)
        guard case .matched(let m) = read.outcome else { Issue.record("nothing"); return }
        #expect(m.first.text.value == "Edit")
        #expect(m.first.frame.centre == ScreenPoint(x: 70, y: 10))
    }

    /// Across two words the narrowing keeps both, and an exact match reports the whole run.
    @Test func narrowingSpansWordsAndLeavesWholeMatchesWhole() {
        let words = ["Save", "As…", "Cancel"].enumerated().map { i, w in
            Word(text: Text(w)!, frame: ScreenRect(x: Double(i) * 50, y: 0, width: 40, height: 20))
        }
        let run = Found(first: words[0], rest: Array(words.dropFirst()), source: .pixels(confidence: Confidence(1)!))
        #expect(Match.contains("save as").narrowing(run).map(\.text.value) == ["Save As…"])
        #expect(Match.exact("Save As… Cancel").narrowing(run) == [run])
    }

    /// A near miss printed one off must match when the caller widens by one edit - inside
    /// a longer run too, which is where Vision puts a menu item.
    @Test func wideningByTheDistanceShownFindsTheNearMiss() {
        let near = judge(["Terminal Shell Setlings Help"], .contains("Settings"))
        guard case .nearest(let n) = near.outcome else { Issue.record("matched"); return }
        #expect(n.first?.distance == 1)
        let widened = judge(["Terminal Shell Setlings Help"], .within(edits: Edits(1)!, of: "Settings"))
        guard case .matched(let m) = widened.outcome else { Issue.record("still nothing"); return }
        #expect(m.all.map(\.text.value) == ["Setlings"])
    }

    /// A run holding the query twice is two matches, not one with the other dropped.
    @Test func aRunHoldingTheQueryTwiceIsTwoMatches() {
        guard case .matched(let m) = judge(["Save Save All Revert"], .contains("save")).outcome else {
            Issue.record("nothing"); return
        }
        #expect(m.all.map(\.text.value) == ["Save", "Save"])
    }

    /// A reader that stopped short stays stopped when the limit also cuts: its own stop is
    /// the earlier cause, and either way the reading proves no absence.
    @Test func aReadersOwnStopOutlastsTheLimit() {
        let read = Reading.judging(["OK", "OK"].enumerated().map { found($1, y: Double($0) * 20) },
                                   query: Query(match: nil, region: .rect(Self.region), limit: Limit(1)!),
                                   region: Self.region, examined: 2, excluded: [], reach: .stopped(.unread))
        #expect(read.scope.reach == .stopped(.unread))
        #expect(read.scope.excluded == [Exclusion(reason: .ranked, count: 1)])
    }
}
