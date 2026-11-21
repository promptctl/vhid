import CoreGraphics
import Seeing
import Grants
import Testing
@testable import Pixels
import ScreenSpace

/// Cutting a region into pieces for Vision and putting the runs back together.
@Suite struct PixelReaderTests {
    private func run(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 14) throws -> Found {
        Found(text: Text(text)!, frame: try ScreenRect(x: x, y: y, width: w, height: h), source: .pixels(confidence: Confidence(1)!))
    }

    /// Every point of the region is in some piece, no piece leaves it, and none is larger
    /// than Vision reads well - on a display at a negative origin, where an offset shows.
    @Test func thePiecesCoverTheRegionAndStayInsideIt() throws {
        let region = try ScreenRect(x: -2400, y: -300, width: 2400, height: 1600)
        let tiles = try PixelReader.tiles(of: region)
        for tile in tiles {
            #expect(tile.width <= PixelReader.tileSide && tile.height <= PixelReader.tileSide)
            #expect(region.contains(tile))
        }
        for x in stride(from: region.x, to: region.x + region.width, by: 37) {
            for y in stride(from: region.y, to: region.y + region.height, by: 37) {
                #expect(try tiles.contains { $0.contains(try ScreenPoint.at(x, y)) }, "\(x),\(y) is in no piece")
            }
        }
    }

    /// Any run up to half a piece wide lies whole inside at least one piece, so a seam
    /// never leaves a short label readable only in halves.
    @Test func aShortRunIsWholeInSomePiece() throws {
        let region = try ScreenRect(x: 0, y: 0, width: 1512, height: 982)
        let tiles = try PixelReader.tiles(of: region)
        for x in stride(from: 0.0, through: region.width - 400, by: 23) {
            let label = try ScreenRect(x: x, y: 390, width: 400, height: 20)
            #expect(tiles.contains { $0.contains(label) }, "a label at \(x) is cut by every piece")
        }
    }

    @Test func aRegionSmallerThanAPieceIsOnePieceItself() throws {
        let small = try ScreenRect(x: 300, y: 0, width: 300, height: 40)
        #expect(try PixelReader.tiles(of: small) == [small])
    }

    /// The same text read by two overlapping pieces, or a piece of it a seam cut, is kept
    /// once; two different labels side by side are both kept.
    @Test func overlappingReadsOfOneRunAreKeptOnce() throws {
        let whole = try run("Save As…", 100, 10, 60)
        let again = try run("Save As…", 100.5, 10, 60)
        let cut = try run("Save", 100, 10, 28)
        let beside = try run("Cancel", 170, 10, 50)
        let kept = PixelReader.distinct([Piece(tile: 0, run: cut), Piece(tile: 1, run: whole), Piece(tile: 2, run: again), Piece(tile: 3, run: beside)]).found
        #expect(kept.count == 2)
        #expect(kept.contains(beside))
        #expect(kept.contains { $0.text.value == "Save As…" })
    }

    /// Menu items that sit a few points off one another's baseline are one line, read left
    /// to right; the line below comes after all of them.
    @Test func runsComeBackTopToBottomThenLeftToRight() throws {
        let order = [
            try run("below", 10, 40, 40), try run("Edit", 180, 12, 30), try run("File", 100, 10, 30), try run("Help", 400, 13, 30),
        ].inReadingOrder
        #expect(order.map(\.text.value) == ["File", "Edit", "Help", "below"])
    }

    static let main = try! ScreenRect(x: 0, y: 0, width: 1512, height: 982)
    static let left = try! ScreenRect(x: -2400, y: -300, width: 2400, height: 1600)

    /// The measured case: 400x300 reaching past the main display's corner is captured as
    /// only its on-screen 212x182, so that is the rectangle the boxes map back through.
    @Test func aRectHangingOffTheDisplayIsReadAsItsOnScreenPart() throws {
        let seen = try PixelReader.onOneDisplay(try ScreenRect(x: 1300, y: 800, width: 400, height: 300), displays: [Self.main, Self.left])
        #expect(seen == (try ScreenRect(x: 1300, y: 800, width: 212, height: 182)))
    }

    /// Across two displays, the part on the other one is on screen and would go unread
    /// while the reading claimed the whole region, so the rectangle is refused.
    @Test func aRectAcrossTwoDisplaysIsRefused() {
        #expect(throws: PixelsError.self) {
            try PixelReader.onOneDisplay(try ScreenRect(x: -100, y: 10, width: 400, height: 50), displays: [Self.main, Self.left])
        }
    }

    @Test func aRectOnNoDisplayIsRefusedNotReadAsBlank() {
        #expect(throws: PixelsError.self) {
            try PixelReader.onOneDisplay(try ScreenRect(x: 9000, y: 9000, width: 40, height: 30), displays: [Self.main, Self.left])
        }
    }

    /// Which runs are the front app's is the hit test's to say, and it says nothing without
    /// Accessibility: a front look by pixels without it is refused naming that grant, before
    /// any capture, rather than read with every run set aside as unknown.
    @Test @MainActor func aFrontLookWithoutAccessibilityIsRefusedNamingIt() async {
        let reader = PixelReader(granted: { $0 == PixelReader.grant }, hit: { _ in .unanswered })
        let front = Front(app: Front.App(pid: 300, name: "System Settings"), display: 1, own: Front.Passed(pids: [80], name: "iTerm2"), passedOver: nil)
        await #expect {
            _ = try await reader.look(Query(match: nil, region: .front(front)))
        } throws: { error in
            guard case PixelsError.noGrant(.accessibility) = error else { return false }
            return "\(error)".contains("Accessibility") && "\(error)".contains(Grant.holderNamedBy)
        }
    }

    /// A line of words, one every 50 points from `from`, as the tile that read them saw it.
    private func line(_ words: [String], from: Double, y: Double = 100) throws -> Found {
        let placed = try words.enumerated().map { i, w in
            Word(text: Text(w)!, frame: try ScreenRect(x: from + Double(i) * 50, y: y, width: 44, height: 14))
        }
        return try #require(Found(first: placed[0], rest: Array(placed.dropFirst()), source: .pixels(confidence: Confidence(0.9)!)))
    }

    /// The reviewer's first case: a line from 300 to 1000 read in three overlapping pieces.
    /// Keeping only the larger piece lost the words from 300 to 400. Joined, every word is
    /// there once.
    @Test func aLineCutByTwoSeamsComesBackWholeAndOnce() throws {
        let all = (0..<14).map { "w\($0)" }       // x 300 ... 950
        let pieces = [
            try line(Array(all[0..<10]), from: 300),  // tile 0-800
            try line(Array(all[2..<14]), from: 400),  // tile 400-1200
            try line(Array(all[10..<14]), from: 800), // tile 800-1600
        ]
        let kept = PixelReader.distinct(pieces.enumerated().map { Piece(tile: $0, run: $1) }).found
        #expect(kept.count == 1)
        #expect(kept.first?.words.map(\.text.value) == all)
    }

    /// The second case: pieces overlapping by only half used to both survive, doubling
    /// every shared word. Joined, none is doubled.
    @Test func overlappingPiecesOfOneLineDoNotDoubleItsWords() throws {
        let all = (0..<20).map { "w\($0)" }
        let kept = try PixelReader.distinct([Piece(tile: 0, run: line(Array(all[0..<14]), from: 100)), Piece(tile: 1, run: line(Array(all[6..<20]), from: 400))]).found
        #expect(kept.map { $0.words.map(\.text.value) } == [all])
    }

    /// A seam fragment of a word is dropped in favour of the whole word at the same spot.
    @Test func aSeamFragmentGivesWayToTheWholeWord() throws {
        let whole = try line(["Open", "Settings"], from: 100)
        let fragment = Found(text: Text("Sett")!, frame: try ScreenRect(x: 150, y: 100, width: 24, height: 14),
                             source: .pixels(confidence: Confidence(0.5)!))
        #expect(PixelReader.distinct([Piece(tile: 0, run: whole), Piece(tile: 1, run: fragment)]).found.map(\.text.value) == ["Open Settings"])
    }

    /// Two lines stacked do not join, however they overlap sideways.
    @Test func linesAboveOneAnotherStayApart() throws {
        #expect(try PixelReader.distinct([Piece(tile: 0, run: line(["a", "b"], from: 0, y: 0)), Piece(tile: 1, run: line(["c", "d"], from: 0, y: 16))]).found.count == 2)
    }

    /// Words of one run are never weighed against each other, even when a padded box
    /// covers its neighbour: only another tile's reading of the same spot can drop one.
    @Test func theWordsOfOneRunAreNeverDroppedAgainstEachOther() throws {
        let wide = Word(text: Text("Shell")!, frame: try ScreenRect(x: 0, y: 0, width: 200, height: 14))
        let inside = Word(text: Text("Edit")!, frame: try ScreenRect(x: 60, y: 0, width: 30, height: 14))
        let run = try #require(Found(first: wide, rest: [inside], source: .pixels(confidence: Confidence(1)!)))
        #expect(PixelReader.distinct([Piece(tile: 0, run: run)]).found.first?.text.value == "Shell Edit")
    }

    /// Two runs one tile read side by side are two runs, however their boxes brush.
    @Test func runsFromOneTileAreNeverJoined() throws {
        let name = try run("Name:", 0, 0, 41), value = try run("Brandon", 40, 0, 60)
        #expect(PixelReader.distinct([Piece(tile: 0, run: name), Piece(tile: 0, run: value)]).found.count == 2)
    }

    /// A half-height misread from a tile whose edge cut the line gives way to the whole
    /// reading, even when it came first and is just as wide.
    @Test func aCutMisreadGivesWayToTheWholeReading() throws {
        let cut = try run("Sove", 100, 100, 40, 7), whole = try run("Save", 100, 100, 40, 14)
        #expect(PixelReader.distinct([Piece(tile: 0, run: cut), Piece(tile: 1, run: whole)]).found.map(\.text.value) == ["Save"])
    }

    /// Every word a join drops is counted: two tiles' readings of one line share eight words.
    /// And a joined line no box can hold - its pieces each a box, reaching past a Double
    /// together - is counted as text read and not placed, rather than dropped.
    @Test func whatAJoinDropsOrCannotHoldIsCounted() throws {
        let all = (0..<20).map { "w\($0)" }
        let joined = try PixelReader.distinct([Piece(tile: 0, run: line(Array(all[0..<14]), from: 100)), Piece(tile: 1, run: line(Array(all[6..<20]), from: 400))])
        #expect(joined.found.count == 1 && joined.dropped == 8 && joined.unjoined == 0)
        // The shared word is wide enough to survive the sums at this scale, where 40 points
        // round away.
        let word = { (text: String, x: Double, width: Double) in Word(text: Text(text)!, frame: try ScreenRect(x: x, y: 0, width: width, height: 14)) }
        let east = try #require(Found(first: word("here", 0, 1e300), rest: [try word("far", 9e307, 40)], source: .pixels(confidence: Confidence(1)!)))
        let west = try #require(Found(first: word("far", -9e307, 40), rest: [try word("here", 0, 1e300)], source: .pixels(confidence: Confidence(1)!)))
        let apart = PixelReader.distinct([Piece(tile: 0, run: east), Piece(tile: 1, run: west)])
        #expect(apart.found.isEmpty && apart.dropped == 1 && apart.unjoined == 1, "\(apart)")
    }

    /// A tile whose fractions below are exact in binary, so every box lands on whole points.
    static let tile = try! ScreenRect(x: 0, y: 0, width: 1024, height: 128)

    /// An observation whose words all land is a run of them, each where Vision put it.
    @Test func anObservationIsARunOfItsPlacedWords() throws {
        let boxes: [Substring: CGRect] = ["Save": CGRect(x: 0.125, y: 0.25, width: 0.0625, height: 0.5), "As": CGRect(x: 0.25, y: 0.25, width: 0.03125, height: 0.5)]
        let seen = PixelReader.observed("Save As", confidence: Confidence(1)!, box: CGRect(x: 0.125, y: 0.25, width: 0.25, height: 0.5), on: Self.tile) { boxes[$0] }
        guard case .run(let run) = seen else { Issue.record("\(seen)"); return }
        #expect(run.words.map(\.text.value) == ["Save", "As"])
        #expect(run.words.map(\.frame) == [try ScreenRect(x: 128, y: 32, width: 64, height: 64), try ScreenRect(x: 256, y: 32, width: 32, height: 64)])
    }

    /// A word Vision cannot place makes the run one word at the observation's own box; with
    /// that box no place either, the observation was read and not placed. No words is none.
    @Test func anObservationThatCannotBePlacedIsCountedNotGuessed() throws {
        let box = CGRect(x: 0.125, y: 0.25, width: 0.25, height: 0.5)
        let unplacedWord = PixelReader.observed("Save As", confidence: Confidence(1)!, box: box, on: Self.tile) {
            $0 == "Save" ? CGRect(x: 0.125, y: 0.25, width: 0.0625, height: 0.5) : CGRect(x: 0.25, y: 0.25, width: 0, height: 0.5)
        }
        guard case .run(let run) = unplacedWord else { Issue.record("\(unplacedWord)"); return }
        #expect(run.text.value == "Save As" && run.words.count == 1)
        #expect(run.frame == (try ScreenRect(x: 128, y: 32, width: 256, height: 64)))
        let nowhere = CGRect(x: Double.nan, y: 0, width: 0.1, height: 0.1)
        #expect(PixelReader.observed("Save As", confidence: Confidence(1)!, box: nowhere, on: Self.tile) { _ in nil } == .unlocated)
        #expect(PixelReader.observed("  ", confidence: Confidence(1)!, box: box, on: Self.tile) { _ in nil } == .wordless)
    }
}

/// The reader looks only when its gate says Screen Recording is held, and asks for nothing else.
@Suite struct PixelGateTests {
    @MainActor @Test func aWithheldGrantRefusesBeforeLooking() async {
        let asked = Asked()
        let reader = PixelReader(granted: { await asked.add($0); return false }, hit: { _ in Issue.record("hit test asked"); return .unanswered })
        await #expect { try await reader.look(Query(match: .contains("Save"), region: .display(1))) } throws: {
            ($0 as? PixelsError)?.missingGrant == true
        }
        #expect(await asked.grants == [.screenRecording])
        #expect(Grant.screenRecording.reader == reader.source)
    }
}

actor Asked {
    var grants: [Grant] = []
    func add(_ grant: Grant) { grants.append(grant) }
}
