import ScreenSpace
import Seeing
import Testing

/// A run is its words and the box holding them: a stretch of it is placed at its own words,
/// and a run found again by another reader keeps its words and its place.
@Suite struct FoundTests {
    static let words = [("Shell", 0.0), ("Edit", 50.0), ("View", 90.0)].map { text, x in
        Word(text: Text(text)!, frame: ScreenRect(x: x, y: 2, width: 30, height: 14)!)
    }
    static let run = Found(first: words[0], rest: Array(words.dropFirst()), source: .pixels(confidence: Confidence(0.9)!))

    @Test func aRunIsPlacedAtTheBoxHoldingItsWords() {
        #expect(Self.run.frame == ScreenRect(x: 0, y: 2, width: 120, height: 14))
        #expect(Self.run.text.value == "Shell Edit View")
    }

    @Test func aStretchIsPlacedAtItsOwnWords() {
        let stretch = Self.run.stretch(1...2)
        #expect(stretch.text.value == "Edit View")
        #expect(stretch.frame == ScreenRect(x: 50, y: 2, width: 70, height: 14))
        #expect(Self.run.stretch(0...0).frame == Self.words[0].frame)
    }

    @Test func aRunFoundAgainKeepsItsWordsAndPlace() {
        let again = Self.run.found(by: .merged(Self.run.source, .pixels(confidence: Confidence(1)!)))
        #expect(again.words == Self.run.words)
        #expect(again.frame == Self.run.frame)
        #expect(again.source != Self.run.source)
    }

    /// One word an app claims far past any display is kept as claimed: a run's words are
    /// placed in the display space only when a reader joins them into one run.
    @Test func aFrameAnAppClaimsIsKeptAsClaimed() {
        let claimed = ScreenRect(x: -400, y: 22, width: 1e20, height: 30)!
        #expect(Found(text: Text("Document")!, frame: claimed, source: .pixels(confidence: Confidence(1)!)).frame == claimed)
    }
}
