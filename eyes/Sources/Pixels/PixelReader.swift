import CoreGraphics
import Eyes
import Foundation
import ImageIO
import Vision

/// Reads the screen as pixels: captures the region, recognises its text on-device with
/// Vision, and hands the runs to the one judge every reader shares.
///
/// Everything here is the edge - the grant, the capture, the recogniser. What counts as a
/// match lives in `Reading.judging`, so this type holds no opinion about the query beyond
/// which rectangle it names. [LAW:effects-at-boundaries]
public struct PixelReader: Reader {
    public let source = SourceKind.pixels

    public init() {}

    public func look(_ query: Query) async throws -> Candidates {
        let region = try Self.resolve(query.region)
        // [LAW:no-silent-failure] Preflight is asked explicitly because capturing without
        // the grant does not fail - it returns the desktop wallpaper with every window
        // blanked, and recognising that is a confident "nothing here".
        guard CGPreflightScreenCaptureAccess() else { throw PixelsError.noGrant }
        let image = try Self.capture(region)
        // A run with no words in it is nil: examined, and counted as wordless.
        // One piece after another, never at once: measured, recognising the pieces in a
        // task group segfaulted inside TextRecognition in 4 runs of 15.
        var runs: [Found?] = []
        var readable: [Piece] = []
        for (index, tile) in Self.tiles(of: region).enumerated() {
            let recognised = try await Self.recognise(image, of: region, in: tile)
            runs += recognised
            readable += recognised.compactMap { $0.map { Piece(tile: index, run: $0) } }
        }

        let distinct = Self.distinct(readable)
        let excluded = [
            Exclusion(reason: .wordless, count: runs.count - readable.count),
            Exclusion(reason: .duplicate, count: readable.count - distinct.count),
        ].filter { $0.count > 0 }
        return Candidates(
            found: distinct.inReadingOrder,
            region: region,
            examined: runs.count,
            excluded: excluded,
            reach: .whole
        )
    }

    /// The side of the largest piece Vision is handed at once, in points.
    ///
    /// Vision scales what it is given down to a working size of its own, and interface
    /// text does not survive that from a large display: measured, a 2400x1600 display at
    /// 1x with a TextEdit window on it recognised nothing at all, and an 1200x800 piece of
    /// the same pixels recognised 16 runs. So the region is read in pieces. Upscaling the
    /// image first was tried and recognised nothing; full-width strips were erratic and
    /// merged unrelated runs.
    nonisolated static let tileSide = 800.0

    /// Overlapping pieces covering `region`, each at most `tileSide` square and stepped by
    /// half of it, so any run up to half a tile wide lies whole inside at least one piece.
    /// A region smaller than a tile is one piece: itself. [LAW:dataflow-not-control-flow]
    nonisolated static func tiles(of region: ScreenRect) -> [ScreenRect] {
        func starts(_ origin: Double, _ length: Double) -> [Double] {
            let side = min(tileSide, length)
            let steps = Int(((length - side) / (tileSide / 2)).rounded(.up))
            return (0...steps).map { origin + min(Double($0) * tileSide / 2, length - side) }
        }
        let (w, h) = (min(tileSide, region.width), min(tileSide, region.height))
        return starts(region.y, region.height).flatMap { y in
            starts(region.x, region.width).map { x in ScreenRect(x: x, y: y, width: w, height: h) }
        }
    }

    /// One run per stretch of text, where overlapping pieces each read some of it.
    ///
    /// Pieces of one line read by different tiles are one line, so they are joined, never
    /// chosen between: a line wider than half a tile comes back as overlapping partial runs,
    /// and keeping only the larger lost the words only the smaller held while the scope
    /// still said the whole region was read. Runs join when they share a line and their
    /// spans overlap; within a joined run, a word mostly inside a wider word at the same
    /// place is the same word read again or cut by a seam, and only the widest is kept.
    /// Labels side by side do not overlap, so they stay apart. [LAW:no-silent-failure]
    nonisolated static func distinct(_ pieces: [Piece]) -> [Found] {
        var groups: [[Piece]] = []
        for piece in pieces {
            let joined = groups.indices.filter { i in groups[i].contains { piece.continues($0) } }
            let merged = joined.flatMap { groups[$0] } + [piece]
            groups = groups.indices.filter { !joined.contains($0) }.map { groups[$0] } + [merged]
        }
        return groups.map(joining)
    }

    /// Joined pieces as one run. A word is dropped only when a larger word read by a
    /// *different* tile covers half of it - the same spot read twice, or cut by a seam - so
    /// the words of one Vision run are never weighed against each other. Larger by area, so
    /// a half-height misread from a tile whose edge cut the line gives way to the whole one.
    nonisolated static func joining(_ pieces: [Piece]) -> Found {
        let words = pieces.flatMap { piece in piece.run.words.map { (tile: piece.tile, word: $0) } }
        var kept: [(tile: Int, word: Word)] = []
        for candidate in words.sorted(by: { $0.word.frame.area > $1.word.frame.area }) {
            let covered = kept.contains {
                $0.tile != candidate.tile && candidate.word.frame.overlap($0.word.frame) >= candidate.word.frame.area / 2
            }
            if !covered { kept.append(candidate) }
        }
        let ordered = kept.map(\.word).sorted { $0.frame.x < $1.frame.x }
        // A joined run is no surer than its least sure piece.
        let confidence = pieces.compactMap { if case .pixels(let c) = $0.run.source { c } else { nil } }.min()!
        return Found(first: ordered[0], rest: Array(ordered.dropFirst()), source: .pixels(confidence: confidence))
    }

    /// The query's region as a rectangle a capture can take: the one `Region.bounds` names,
    /// clipped to the display it lies on.
    @MainActor
    static func resolve(_ region: Region) throws -> ScreenRect {
        try onOneDisplay(region.bounds(), displays: Geometry.displays().map(\.frame))
    }

    /// The part of `rect` a capture can see, on the one display it lies on, in whole points.
    /// The scope line prints this and not what was asked for, so a window hanging off the
    /// edge of the desk is read as what is on screen and says so.
    ///
    /// [LAW:no-silent-failure] Measured, `screencapture` handed 400x300 points reaching past
    /// the display's corner returns an image of only the on-screen 212x182, and mapping that
    /// back across the full rectangle stretches every point. Clipping first keeps the image
    /// and the rectangle the same shape; a rectangle on no display is refused, not read as
    /// blank. Whole points because the capture takes whole points, and the rectangle boxes
    /// are mapped back through must be the one that was captured.
    nonisolated static func onOneDisplay(_ rect: ScreenRect, displays: [ScreenRect]) throws -> ScreenRect {
        let seen = displays.map { $0.cgRect.intersection(rect.cgRect.integral) }
            .filter { !$0.isNull && !$0.isEmpty }
        // Across two displays, the part on the other one is on screen and would go unread
        // while the reading claimed the whole region, so it is refused by name instead.
        guard seen.count <= 1 else { throw PixelsError.spansDisplays(rect) }
        guard let only = seen.first else { throw PixelsError.offScreen(rect) }
        return ScreenRect(only.integral)
    }

    /// Captures exactly `region` with `screencapture`, in points of the global space it
    /// already speaks.
    ///
    /// [LAW:no-silent-failure] Its exit status is not evidence: measured, it exits 0 having
    /// written nothing when the path is unwritable. The file it wrote, decoded, is the only
    /// proof a capture happened.
    nonisolated static func capture(_ region: ScreenRect) throws -> CGImage {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eyes-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let r = region.cgRect
        process.arguments = ["-x", "-t", "png", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", path.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
              // Decoded now, not on first use: the image is lazy by default, and the file
              // under it is deleted on the way out - measured, a lazy image read after
              // that recognises nothing at all, which prints as a blank screen.
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else {
            let said = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PixelsError.captureWroteNothing(region, said.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // The backstop for the clipping above: an image not the shape of the rectangle
        // would map every box to the wrong place, so it is refused rather than read.
        let (imageAspect, regionAspect) = (Double(image.width) / Double(image.height), region.width / region.height)
        guard abs(imageAspect / regionAspect - 1) < 0.02 else {
            throw PixelsError.captureWrongShape(region, width: image.width, height: image.height)
        }
        return image
    }

    /// Vision's runs in one piece of the image, placed on the screen word by word. Runs
    /// rather than one row per word, because a run is what a person reads as one label and
    /// rows per word multiply what a caller pays for the same screen - but each run keeps
    /// where its words sit, so a match inside one can be narrowed to them.
    ///
    /// Vision answers inside the region of interest as fractions of that region, so the
    /// piece is the rectangle each box is converted on - the one conversion, applied to a
    /// smaller display. [LAW:single-enforcer]
    nonisolated static func recognise(_ image: CGImage, of region: ScreenRect, in tile: ScreenRect) async throws -> [Found?] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.regionOfInterest = NormalizedRect(normalizedRect: tile.normalized(in: region))
        return try await request.perform(on: image).map { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            guard let confidence = Confidence(Double(best.confidence)) else {
                throw PixelsError.unreadableConfidence(best.string)
            }
            let place = { (box: NormalizedRect) in ScreenRect.fromImageSpace(normalized: box.cgRect, on: tile) }
            let source = Source.pixels(confidence: confidence)
            let words = best.string.split(whereSeparator: \.isWhitespace).map { word in
                (text: Text(String(word))!, box: best.boundingBox(for: word.startIndex..<word.endIndex)?.boundingBox)
            }
            // A run with a word Vision cannot place stays one word at the run's own box,
            // rather than placing that word as if it covered the whole line.
            guard words.allSatisfy({ $0.box != nil }) else {
                return Text(best.string).map { Found(text: $0, frame: place(observation.boundingBox), source: source) }
            }
            let placed = words.map { Word(text: $0.text, frame: place($0.box!)) }
            return placed.first.map { Found(first: $0, rest: Array(placed.dropFirst()), source: source) }
        }
    }
}

/// A run and the tile that read it, which is what tells the same text read twice by
/// overlapping tiles apart from two things one tile read side by side.
struct Piece {
    let tile: Int
    let run: Found

    /// Another tile's reading of the same stretch: on one line - the vertical spans share
    /// at least half the shorter height - and overlapping sideways.
    func continues(_ other: Piece) -> Bool {
        let (a, b) = (run.frame, other.run.frame)
        let shared = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return tile != other.tile && a.intersects(b) && shared >= min(a.height, b.height) / 2
    }
}

/// Everything that means the reader could not look, as opposed to having looked and found
/// nothing. Each one throws, because a returned `Reading` is taken as proof of looking.
public enum PixelsError: Error, CustomStringConvertible {
    case noGrant
    case offScreen(ScreenRect)
    case spansDisplays(ScreenRect)
    case captureWrongShape(ScreenRect, width: Int, height: Int)
    case captureWroteNothing(ScreenRect, String)
    case unreadableConfidence(String)

    public var description: String {
        switch self {
        case .noGrant:
            "Screen Recording is not granted to this process, so a capture would show only the wallpaper."
                + " Grant it in System Settings > Privacy & Security > Screen Recording."
        case .offScreen(let r):
            "\(r) is on no display, so there is nothing there to read"
        case .spansDisplays(let r):
            "\(r) lies across more than one display; read each display's part with its own --rect or --display"
        case .captureWrongShape(let r, let width, let height):
            "screencapture returned a \(width)x\(height) pixel image for \(r), which is not its shape"
        case .captureWroteNothing(let r, let said):
            "screencapture wrote no image of \(r)"
                + (said.isEmpty ? "" : ": \(said)")
        case .unreadableConfidence(let text):
            "Vision reported a confidence that is not a number for \"\(text)\""
        }
    }
}
