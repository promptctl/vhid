import Eyes
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
        let kept = PixelReader.distinct([cut, whole, again, beside])
        #expect(kept.count == 2)
        #expect(kept.contains(beside))
        #expect(kept.contains { $0.text.value == "Save As…" })
    }

    /// Menu items that sit a few points off one another's baseline are one line, read left
    /// to right; the line below comes after all of them.
    @Test func runsComeBackTopToBottomThenLeftToRight() {
        let order = PixelReader.readingOrder([
            run("below", 10, 40, 40), run("Edit", 180, 12, 30), run("File", 100, 10, 30), run("Help", 400, 13, 30),
        ])
        #expect(order.map(\.text.value) == ["File", "Edit", "Help", "below"])
    }
}
