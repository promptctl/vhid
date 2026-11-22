import Grants
import ScreenSpace
import ScreenSpaceTesting
import Seeing
import Testing
@testable import Pixels

/// Cutting a region into pieces for Vision and putting the runs back together.
@Suite struct PixelReaderTests {
    private func run(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 14) -> Found {
        try! Found(text: Text(text)!, frame: ScreenRect.at(x, y, w, h), source: .pixels(confidence: Confidence(1)!), within: Self.main, on: .vast)
    }

    /// The runs the pieces join into, each one placed: a run left unshown is an issue here,
    /// where every piece lies on the display.
    private func distinct(_ pieces: [Piece]) -> [Found] {
        PixelReader.distinct(pieces).compactMap {
            guard case .found(let run) = $0 else { Issue.record("\($0)"); return nil }
            return run
        }
    }

    /// Every point of the region is in some piece, no piece leaves it, and none is larger
    /// than Vision reads well - on a display at a negative origin, where an offset shows.
    @Test func thePiecesCoverTheRegionAndStayInsideIt() throws {
        let region = ScreenRect.at(-2400, -300, 2400, 1600)
        let tiles = try PixelReader.tiles(of: region)
        for tile in tiles {
            #expect(tile.width <= PixelReader.tileSide && tile.height <= PixelReader.tileSide)
            #expect(region.cgRect.contains(tile.cgRect))
        }
        for x in stride(from: region.x, to: region.x + region.width, by: 37) {
            for y in stride(from: region.y, to: region.y + region.height, by: 37) {
                #expect(tiles.contains { $0.contains(ScreenPoint.at(x, y)) }, "\(x),\(y) is in no piece")
            }
        }
    }

    /// Any run up to half a piece wide lies whole inside at least one piece, so a seam
    /// never leaves a short label readable only in halves.
    @Test func aShortRunIsWholeInSomePiece() throws {
        let region = ScreenRect.at(0, 0, 1512, 982)
        let tiles = try PixelReader.tiles(of: region)
        for x in stride(from: 0.0, through: region.width - 400, by: 23) {
            let label = ScreenRect.at(x, 390, 400, 20)
            #expect(tiles.contains { $0.cgRect.contains(label.cgRect) }, "a label at \(x) is cut by every piece")
        }
    }

    @Test func aRegionSmallerThanAPieceIsOnePieceItself() throws {
        let small = ScreenRect.at(300, 0, 300, 40)
        #expect(try PixelReader.tiles(of: small) == [small])
    }

    /// The same text read by two overlapping pieces, or a piece of it a seam cut, is kept
    /// once; two different labels side by side are both kept.
    @Test func overlappingReadsOfOneRunAreKeptOnce() {
        let whole = run("Save As…", 100, 10, 60)
        let again = run("Save As…", 100.5, 10, 60)
        let cut = run("Save", 100, 10, 28)
        let beside = run("Cancel", 170, 10, 50)
        let kept = distinct([Piece(tile: 0, run: cut), Piece(tile: 1, run: whole), Piece(tile: 2, run: again), Piece(tile: 3, run: beside)])
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

    static let main = ScreenRect.at(0, 0, 1512, 982)
    static let left = ScreenRect.at(-2400, -300, 2400, 1600)

    /// The measured case: 400x300 reaching past the main display's corner is captured as
    /// only its on-screen 212x182, so that is the rectangle the boxes map back through.
    @Test func aRectHangingOffTheDisplayIsReadAsItsOnScreenPart() throws {
        let seen = try PixelReader.onOneDisplay(ScreenRect.at(1300, 800, 400, 300), displays: [Self.main, Self.left])
        #expect(seen == ScreenRect.at(1300, 800, 212, 182))
    }

    /// Across two displays, the part on the other one is on screen and would go unread
    /// while the reading claimed the whole region, so the rectangle is refused.
    @Test func aRectAcrossTwoDisplaysIsRefused() {
        #expect(throws: PixelsError.self) {
            try PixelReader.onOneDisplay(ScreenRect.at(-100, 10, 400, 50), displays: [Self.main, Self.left])
        }
    }

    @Test func aRectOnNoDisplayIsRefusedNotReadAsBlank() {
        #expect(throws: PixelsError.self) {
            try PixelReader.onOneDisplay(ScreenRect.at(9000, 9000, 40, 30), displays: [Self.main, Self.left])
        }
    }

    /// Which runs are the front app's is the hit test's to say, and it says nothing without
    /// Accessibility: a front look by pixels without it is refused naming that grant, before
    /// any capture, rather than read with every run set aside as unknown.
    @Test @MainActor func aFrontLookWithoutAccessibilityIsRefusedNamingIt() async {
        let reader = PixelReader(granted: { $0 == PixelReader.grant }, hit: { _ in .unanswered })
        let front = Front(app: Front.App(pid: 300, name: "System Settings"), display: 1, own: Front.Passed(pids: [80], name: "iTerm2"), passedOver: nil)
        await #expect {
            _ = try await reader.look(Query(match: nil, region: .front(front)), on: .single)
        } throws: { error in
            guard case PixelsError.noGrant(.accessibility) = error else { return false }
            return "\(error)".contains("Accessibility") && "\(error)".contains(Grant.holderNamedBy)
        }
    }

    /// A line of words, one every 50 points from `from`, as the tile that read them saw it.
    private func line(_ words: [String], from: Double, y: Double = 100) -> Found {
        let placed = words.enumerated().map { i, w in
            Word(text: Text(w)!, frame: ScreenRect.at(from + Double(i) * 50, y, 44, 14))
        }
        return try! Found(first: placed[0], rest: Array(placed.dropFirst()), source: .pixels(confidence: Confidence(0.9)!), within: Self.main, on: .vast)
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
        let kept = distinct(pieces.enumerated().map { Piece(tile: $0, run: $1) })
        #expect(kept.count == 1)
        #expect(kept.first?.words.map(\.text.value) == all)
    }

    /// The second case: pieces overlapping by only half used to both survive, doubling
    /// every shared word. Joined, none is doubled.
    @Test func overlappingPiecesOfOneLineDoNotDoubleItsWords() {
        let all = (0..<20).map { "w\($0)" }
        let kept = distinct([Piece(tile: 0, run: line(Array(all[0..<14]), from: 100)), Piece(tile: 1, run: line(Array(all[6..<20]), from: 400))])
        #expect(kept.map { $0.words.map(\.text.value) } == [all])
    }

    /// A seam fragment of a word is dropped in favour of the whole word at the same spot.
    @Test func aSeamFragmentGivesWayToTheWholeWord() {
        let whole = line(["Open", "Settings"], from: 100)
        let fragment = try! Found(text: Text("Sett")!, frame: ScreenRect.at(150, 100, 24, 14),
                             source: .pixels(confidence: Confidence(0.5)!), within: Self.main, on: .vast)
        #expect(distinct([Piece(tile: 0, run: whole), Piece(tile: 1, run: fragment)]).map(\.text.value) == ["Open Settings"])
    }

    /// Two lines stacked do not join, however they overlap sideways.
    @Test func linesAboveOneAnotherStayApart() {
        #expect(distinct([Piece(tile: 0, run: line(["a", "b"], from: 0, y: 0)), Piece(tile: 1, run: line(["c", "d"], from: 0, y: 16))]).count == 2)
    }

    /// Words of one run are never weighed against each other, even when a padded box
    /// covers its neighbour: only another tile's reading of the same spot can drop one.
    @Test func theWordsOfOneRunAreNeverDroppedAgainstEachOther() {
        let wide = Word(text: Text("Shell")!, frame: ScreenRect.at(0, 0, 200, 14))
        let inside = Word(text: Text("Edit")!, frame: ScreenRect.at(60, 0, 30, 14))
        let run = try! Found(first: wide, rest: [inside], source: .pixels(confidence: Confidence(1)!), within: Self.main, on: .vast)
        #expect(distinct([Piece(tile: 0, run: run)]).first?.text.value == "Shell Edit")
    }

    /// Two runs one tile read side by side are two runs, however their boxes brush.
    @Test func runsFromOneTileAreNeverJoined() {
        let name = run("Name:", 0, 0, 41), value = run("Brandon", 40, 0, 60)
        #expect(distinct([Piece(tile: 0, run: name), Piece(tile: 0, run: value)]).count == 2)
    }

    /// A half-height misread from a tile whose edge cut the line gives way to the whole
    /// reading, even when it came first and is just as wide.
    @Test func aCutMisreadGivesWayToTheWholeReading() {
        let cut = run("Sove", 100, 100, 40, 7), whole = run("Save", 100, 100, 40, 14)
        #expect(distinct([Piece(tile: 0, run: cut), Piece(tile: 1, run: whole)]).map(\.text.value) == ["Save"])
    }
}

/// The reader looks only when its gate says Screen Recording is held, and asks for nothing else.
@Suite struct PixelGateTests {
    @MainActor @Test func aWithheldGrantRefusesBeforeLooking() async {
        let asked = Asked()
        let reader = PixelReader(granted: { await asked.add($0); return false }, hit: { _ in Issue.record("hit test asked"); return .unanswered })
        await #expect { try await reader.look(Query(match: .contains("Save"), region: .display(1)), on: .single) } throws: {
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
