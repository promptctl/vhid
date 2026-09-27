import CoreGraphics

public extension Region {
    /// The rectangle this region names, in the one screen space, or a refusal naming what
    /// is not there - a display that is not attached reads as blindness, never as a blank
    /// screen. [LAW:no-silent-failure]
    ///
    /// [LAW:single-enforcer] Every reader resolves a region here, so a display id or a
    /// window id means one rectangle whichever reader was asked. What a reader then does
    /// with it - a capture clipping it to one display - is that reader's own business.
    @MainActor
    func bounds() throws -> ScreenRect {
        switch self {
        case .rect(let rect):
            // A rectangle on no display has nothing in it to read, and a reader that walked
            // it would report a blank screen. [LAW:no-silent-failure]
            guard Geometry.displays().contains(where: { $0.frame.intersects(rect) }) else { throw NoSuchPlace.offScreen(rect) }
            return rect
        case .display(let id):
            // The listing `eyes displays` prints, so an id it did not list is refused here.
            guard let display = Geometry.displays().first(where: { $0.id == id }) else { throw NoSuchPlace.display(id) }
            return display.frame
        case .window(let id):
            guard let window = try Geometry.onScreen().windows.first(where: { $0.id == id }) else {
                throw NoSuchPlace.window(id)
            }
            return window.frame
        }
    }
}

/// One attached display, as a caller needs it to aim: the id `Region.display` names, and
/// where it sits in the one screen space.
public struct Display: Sendable, Hashable {
    public let id: CGDirectDisplayID
    /// Global top-left screen points: negative on a display left of or above the main one.
    public let frame: ScreenRect
    /// The display whose top-left corner is the origin of that space.
    public let isMain: Bool
    /// Backing pixels per point, which is what a capture of it is sized by. Absent when the
    /// display mode could not be read, rather than guessed as 1. [LAW:no-silent-failure]
    public let scale: Double?

    public init(id: CGDirectDisplayID, frame: ScreenRect, isMain: Bool, scale: Double?) {
        self.id = id
        self.frame = frame
        self.isMain = isMain
        self.scale = scale
    }
}

public extension Geometry {
    /// Every active display, main first - sorted so, because under mirroring the display
    /// list puts the largest drawable display first, not the main one. One reading for every caller, so the displays `eyes displays` lists are the
    /// ones a region is checked against. [LAW:one-source-of-truth]
    static func displays() -> [Display] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { id in
            // Both widths from the mode, which is unrotated; the bounds are rotated, and a
            // portrait display divided by them reads 1.78x instead of 1x.
            let mode = CGDisplayCopyDisplayMode(id)
            return Display(
                id: id, frame: ScreenRect(CGDisplayBounds(id)), isMain: CGDisplayIsMain(id) != 0,
                scale: mode.flatMap { $0.width > 0 ? Double($0.pixelWidth) / Double($0.width) : nil })
        }.sorted { $0.isMain && !$1.isMain }
    }
}

/// A region naming something that is not on screen.
public enum NoSuchPlace: Error, CustomStringConvertible {
    case display(CGDirectDisplayID)
    case window(UInt32)
    case offScreen(ScreenRect)

    public var description: String {
        switch self {
        case .offScreen(let r): "\(r) is on no display, so there is nothing there to read"
        case .display(let id): "no display with id \(id) is attached"
        case .window(let id): "no on-screen window has id \(id); `eyes windows` lists the ones that do"
        }
    }
}

public extension Array where Element == Found {
    /// Top to bottom, then left to right. Neither reader's own order is reading order:
    /// Vision put a menu's third item after the window title below it, and the tree walks
    /// containers before what they contain. A run belongs to the line above it while its
    /// centre falls inside that line's first run; a fixed grid split one menu bar in two,
    /// because its items do not share a baseline to the point.
    var inReadingOrder: [Found] {
        var lines: [[Found]] = []
        for run in sorted(by: { $0.frame.centre.y < $1.frame.centre.y }) {
            if let first = lines.last?.first, run.frame.centre.y < first.frame.y + first.frame.height {
                lines[lines.count - 1].append(run)
            } else {
                lines.append([run])
            }
        }
        return lines.flatMap { $0.sorted { $0.frame.x < $1.frame.x } }
    }
}
