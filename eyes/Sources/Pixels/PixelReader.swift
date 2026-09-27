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

    public func read(_ query: Query) async throws -> Reading {
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
        for tile in Self.tiles(of: region) {
            runs += try await Self.recognise(image, of: region, in: tile)
        }

        let readable = runs.compactMap { $0 }
        let distinct = Self.distinct(readable)
        let excluded = [
            Exclusion(reason: .wordless, count: runs.count - readable.count),
            Exclusion(reason: .duplicate, count: readable.count - distinct.count),
        ].filter { $0.count > 0 }
        return Reading.judging(
            Self.readingOrder(distinct),
            query: query,
            region: region,
            examined: runs.count,
            excluded: excluded
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
    nonisolated static func distinct(_ runs: [Found]) -> [Found] {
        var groups: [[Found]] = []
        for run in runs {
            let joined = groups.indices.filter { i in groups[i].contains { sameStretch($0.frame, run.frame) } }
            let merged = joined.flatMap { groups[$0] } + [run]
            groups = groups.indices.filter { !joined.contains($0) }.map { groups[$0] } + [merged]
        }
        return groups.map(joining)
    }

    /// One line, overlapping: the vertical spans share at least half the shorter height and
    /// the horizontal spans overlap at all.
    nonisolated static func sameStretch(_ a: ScreenRect, _ b: ScreenRect) -> Bool {
        let shared = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return shared >= min(a.height, b.height) / 2 && a.x < b.x + b.width && b.x < a.x + a.width
    }

    nonisolated static func joining(_ pieces: [Found]) -> Found {
        var kept: [Word] = []
        for word in pieces.flatMap(\.words).sorted(by: { $0.frame.width > $1.frame.width }) {
            let area = word.frame.width * word.frame.height
            if !kept.contains(where: { word.frame.cgRect.intersection($0.frame.cgRect).area >= area / 2 }) {
                kept.append(word)
            }
        }
        let ordered = kept.sorted { $0.frame.x < $1.frame.x }
        // The least sure piece speaks for the whole: a joined run is no surer than its weakest reading.
        let confidence = pieces.compactMap { if case .pixels(let c) = $0.source { c } else { nil } }.min()!
        return Found(first: ordered[0], rest: Array(ordered.dropFirst()), source: .pixels(confidence: confidence))
    }

    /// Top to bottom, then left to right. Vision's own order is not reading order - it put
    /// a menu's third item after the window title below it. A run belongs to the line
    /// above it while its centre falls inside that line's first run; a fixed grid split
    /// one menu bar in two, because its items do not share a baseline to the point.
    nonisolated static func readingOrder(_ runs: [Found]) -> [Found] {
        var lines: [[Found]] = []
        for run in runs.sorted(by: { $0.frame.centre.y < $1.frame.centre.y }) {
            if let first = lines.last?.first, run.frame.centre.y < first.frame.y + first.frame.height {
                lines[lines.count - 1].append(run)
            } else {
                lines.append([run])
            }
        }
        return lines.flatMap { $0.sorted { $0.frame.x < $1.frame.x } }
    }

    /// The query's region as a rectangle in screen space, or a refusal naming what does not
    /// exist - a display that is not attached reads as blindness, never as a blank screen.
    @MainActor
    static func resolve(_ region: Region) throws -> ScreenRect {
        let named: ScreenRect
        switch region {
        case .rect(let rect):
            named = rect
        case .display(let id):
            let bounds = CGDisplayBounds(id)
            guard !bounds.isEmpty else { throw PixelsError.noSuchDisplay(id) }
            named = ScreenRect(bounds)
        case .window(let id):
            guard let window = try Geometry.onScreen().windows.first(where: { $0.id == id }) else {
                throw PixelsError.noSuchWindow(id)
            }
            named = window.frame
        }
        return try onOneDisplay(named, displays: activeDisplays())
    }

    /// The part of `rect` a capture can see: on the display it overlaps most, in whole
    /// points. The scope line prints this and not what was asked for, so a window hanging
    /// off the edge is read as what is on screen and says so.
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
            .max { $0.width * $0.height < $1.width * $1.height }
        guard let seen else { throw PixelsError.offScreen(rect) }
        return ScreenRect(seen.integral)
    }

    static func activeDisplays() -> [ScreenRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { ScreenRect(CGDisplayBounds($0)) }
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
            let words = best.string.split(whereSeparator: \.isWhitespace).compactMap { word -> Word? in
                // A word Vision cannot place is placed as the whole run, which holds it.
                let box = best.boundingBox(for: word.startIndex..<word.endIndex)?.boundingBox ?? observation.boundingBox
                return Text(String(word)).map { Word(text: $0, frame: .fromImageSpace(normalized: box.cgRect, on: tile)) }
            }
            return words.first.map { Found(first: $0, rest: Array(words.dropFirst()), source: .pixels(confidence: confidence)) }
        }
    }
}

/// Everything that means the reader could not look, as opposed to having looked and found
/// nothing. Each one throws, because a returned `Reading` is taken as proof of looking.
public enum PixelsError: Error, CustomStringConvertible {
    case noGrant
    case offScreen(ScreenRect)
    case captureWrongShape(ScreenRect, width: Int, height: Int)
    case noSuchDisplay(CGDirectDisplayID)
    case noSuchWindow(UInt32)
    case captureWroteNothing(ScreenRect, String)
    case unreadableConfidence(String)

    public var description: String {
        switch self {
        case .noGrant:
            "Screen Recording is not granted to this process, so a capture would show only the wallpaper."
                + " Grant it in System Settings > Privacy & Security > Screen Recording."
        case .offScreen(let r):
            "\(r) is on no display, so there is nothing there to read"
        case .captureWrongShape(let r, let width, let height):
            "screencapture returned a \(width)x\(height) pixel image for \(r), which is not its shape"
        case .noSuchDisplay(let id):
            "no display with id \(id) is attached"
        case .noSuchWindow(let id):
            "no on-screen window has id \(id); `eyes windows` lists the ones that do"
        case .captureWroteNothing(let r, let said):
            "screencapture wrote no image of \(r)"
                + (said.isEmpty ? "" : ": \(said)")
        case .unreadableConfidence(let text):
            "Vision reported a confidence that is not a number for \"\(text)\""
        }
    }
}

private extension CGRect {
    var area: Double { isNull ? 0 : width * height }
}
