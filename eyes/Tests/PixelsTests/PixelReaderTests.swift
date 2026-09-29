import Eyes
import Grants
import Testing
@testable import Pixels

/// Cutting a region into pieces for Vision and putting the runs back together.
@Suite struct PixelReaderTests {
    private func run(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 14) -> Found {
        Found(text: Text(text)!, frame: ScreenRect(x: x, y: y, width: w, height: h), source: .pixels(confidence: Confidence(1)!))
    }

    /// Every point of the region is in some piece, no piece leaves it, and none is larger
    /// than Vision reads well - on a display at a negative origin, where an offset shows.
    @Test func thePiecesCoverTheRegionAndStayInsideIt() {
        let region = ScreenRect(x: -2400, y: -300, width: 2400, height: 1600)
        let tiles = PixelReader.tiles(of: region)
        for tile in tiles {
            #expect(tile.width <= PixelReader.tileSide && tile.height <= PixelReader.tileSide)
            #expect(region.cgRect.contains(tile.cgRect))
        }
        for x in stride(from: region.x, to: region.x + region.width, by: 37) {
            for y in stride(from: region.y, to: region.y + region.height, by: 37) {
                #expect(tiles.contains { $0.contains(ScreenPoint(x: x, y: y)) }, "\(x),\(y) is in no piece")
            }
        }
    }

    /// Any run up to half a piece wide lies whole inside at least one piece, so a seam
    /// never leaves a short label readable only in halves.
    @Test func aShortRunIsWholeInSomePiece() {
        let region = ScreenRect(x: 0, y: 0, width: 1512, height: 982)
        let tiles = PixelReader.tiles(of: region)
        for x in stride(from: 0.0, through: region.width - 400, by: 23) {
            let label = ScreenRect(x: x, y: 390, width: 400, height: 20)
            #expect(tiles.contains { $0.cgRect.contains(label.cgRect) }, "a label at \(x) is cut by every piece")
        }
    }

    @Test func aRegionSmallerThanAPieceIsOnePieceItself() {
        let small = ScreenRect(x: 300, y: 0, width: 300, height: 40)
        #expect(PixelReader.tiles(of: small) == [small])
    }

    /// The same text read by two overlapping pieces, or a piece of it a seam cut, is kept
    /// once; two different labels side by side are both kept.
    @Test func overlappingReadsOfOneRunAreKeptOnce() {
        let whole = run("Save As…", 100, 10, 60)
        let again = run("Save As…", 100.5, 10, 60)
        let cut = run("Save", 100, 10, 28)
        let beside = run("Cancel", 170, 10, 50)
        let kept = PixelReader.distinct([Piece(tile: 0, run: cut), Piece(tile: 1, run: whole), Piece(tile: 2, run: again), Piece(tile: 3, run: beside)])
        #expect(kept.count == 2)
        #expect(kept.contains(beside))
        #expect(kept.contains { $0.text.value == "Save As…" })
    }

    /// Menu items that sit a few points off one another's baseline are one line, read left
    /// to right; the line below comes after all of them.
    @Test func runsComeBackTopToBottomThenLeftToRight() {
        let order = [
            run("below", 10, 40, 40), run("Edit", 180, 12, 30), run("File", 100, 10, 30), run("Help", 400, 13, 30),
        ].inReadingOrder
        #expect(order.map(\.text.value) == ["File", "Edit", "Help", "below"])
    }

    static let main = ScreenRect(x: 0, y: 0, width: 1512, height: 982)
    static let left = ScreenRect(x: -2400, y: -300, width: 2400, height: 1600)

    /// The measured case: 400x300 reaching past the main display's corner is captured as
    /// only its on-screen 212x182, so that is the rectangle the boxes map back through.
    @Test func aRectHangingOffTheDisplayIsReadAsItsOnScreenPart() throws {
        let seen = try PixelReader.onOneDisplay(ScreenRect(x: 1300, y: 800, width: 400, height: 300), displays: [Self.main, Self.left])
        #expect(seen == ScreenRect(x: 1300, y: 800, width: 212, height: 182))
    }

    /// Across two displays, the part on the other one is on screen and would go unread
    /// while the reading claimed the whole region, so the rectangle is refused.
    @Test func aRectAcrossTwoDisplaysIsRefused() {
        #expect(throws: PixelsError.self) {
            try PixelReader.onOneDisplay(ScreenRect(x: -100, y: 10, width: 400, height: 50), displays: [Self.main, Self.left])
        }
    }

    @Test func aRectOnNoDisplayIsRefusedNotReadAsBlank() {
        #expect(throws: PixelsError.self) {
            try PixelReader.onOneDisplay(ScreenRect(x: 9000, y: 9000, width: 40, height: 30), displays: [Self.main, Self.left])
        }
    }

    /// A line of words, one every 50 points from `from`, as the tile that read them saw it.
    private func line(_ words: [String], from: Double, y: Double = 100) -> Found {
        let placed = words.enumerated().map { i, w in
            Word(text: Text(w)!, frame: ScreenRect(x: from + Double(i) * 50, y: y, width: 44, height: 14))
        }
        return Found(first: placed[0], rest: Array(placed.dropFirst()), source: .pixels(confidence: Confidence(0.9)!))
    }

    /// The reviewer's first case: a line from 300 to 1000 read in three overlapping pieces.
    /// Keeping only the larger piece lost the words from 300 to 400. Joined, every word is
    /// there once.
    @Test func aLineCutByTwoSeamsComesBackWholeAndOnce() {
        let all = (0..<14).map { "w\($0)" }       // x 300 ... 950
        let pieces = [
            line(Array(all[0..<10]), from: 300),  // tile 0-800
            line(Array(all[2..<14]), from: 400),  // tile 400-1200
            line(Array(all[10..<14]), from: 800), // tile 800-1600
        ]
        let kept = PixelReader.distinct(pieces.enumerated().map { Piece(tile: $0, run: $1) })
        #expect(kept.count == 1)
        #expect(kept.first?.words.map(\.text.value) == all)
    }

    /// The second case: pieces overlapping by only half used to both survive, doubling
    /// every shared word. Joined, none is doubled.
    @Test func overlappingPiecesOfOneLineDoNotDoubleItsWords() {
        let all = (0..<20).map { "w\($0)" }
        let kept = PixelReader.distinct([Piece(tile: 0, run: line(Array(all[0..<14]), from: 100)), Piece(tile: 1, run: line(Array(all[6..<20]), from: 400))])
        #expect(kept.map { $0.words.map(\.text.value) } == [all])
    }

    /// A seam fragment of a word is dropped in favour of the whole word at the same spot.
    @Test func aSeamFragmentGivesWayToTheWholeWord() {
        let whole = line(["Open", "Settings"], from: 100)
        let fragment = Found(text: Text("Sett")!, frame: ScreenRect(x: 150, y: 100, width: 24, height: 14),
                             source: .pixels(confidence: Confidence(0.5)!))
        #expect(PixelReader.distinct([Piece(tile: 0, run: whole), Piece(tile: 1, run: fragment)]).map(\.text.value) == ["Open Settings"])
    }

    /// Two lines stacked do not join, however they overlap sideways.
    @Test func linesAboveOneAnotherStayApart() {
        #expect(PixelReader.distinct([Piece(tile: 0, run: line(["a", "b"], from: 0, y: 0)), Piece(tile: 1, run: line(["c", "d"], from: 0, y: 16))]).count == 2)
    }

    /// Words of one run are never weighed against each other, even when a padded box
    /// covers its neighbour: only another tile's reading of the same spot can drop one.
    @Test func theWordsOfOneRunAreNeverDroppedAgainstEachOther() {
        let wide = Word(text: Text("Shell")!, frame: ScreenRect(x: 0, y: 0, width: 200, height: 14))
        let inside = Word(text: Text("Edit")!, frame: ScreenRect(x: 60, y: 0, width: 30, height: 14))
        let run = Found(first: wide, rest: [inside], source: .pixels(confidence: Confidence(1)!))
        #expect(PixelReader.distinct([Piece(tile: 0, run: run)]).first?.text.value == "Shell Edit")
    }

    /// Two runs one tile read side by side are two runs, however their boxes brush.
    @Test func runsFromOneTileAreNeverJoined() {
        let name = run("Name:", 0, 0, 41), value = run("Brandon", 40, 0, 60)
        #expect(PixelReader.distinct([Piece(tile: 0, run: name), Piece(tile: 0, run: value)]).count == 2)
    }

    /// A half-height misread from a tile whose edge cut the line gives way to the whole
    /// reading, even when it came first and is just as wide.
    @Test func aCutMisreadGivesWayToTheWholeReading() {
        let cut = run("Sove", 100, 100, 40, 7), whole = run("Save", 100, 100, 40, 14)
        #expect(PixelReader.distinct([Piece(tile: 0, run: cut), Piece(tile: 1, run: whole)]).map(\.text.value) == ["Save"])
    }
}

/// The reader looks only when its gate says Screen Recording is held, and asks for nothing else.
@Suite struct PixelGateTests {
    @MainActor @Test func aWithheldGrantRefusesBeforeLooking() async {
        let asked = Asked()
        let reader = PixelReader { await asked.add($0); return false }
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
