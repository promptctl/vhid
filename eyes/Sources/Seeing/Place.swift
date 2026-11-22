import CoreGraphics
import ScreenSpace

public extension Region {
    /// The rectangle this region names, in the one screen space, on `layout`'s active
    /// displays, or a refusal naming what is not there - a display that is not active reads
    /// as blindness, never as a blank screen. [LAW:no-silent-failure]
    ///
    /// [LAW:single-enforcer] Every reader resolves a region here, so a display id or a
    /// window id means one rectangle whichever reader was asked. What a reader then does
    /// with it - a capture clipping it to one display - is that reader's own business.
    @MainActor
    func bounds(on layout: DisplayLayout) throws -> ScreenRect {
        switch self {
        case .rect(let rect):
            // A rectangle no display shows a point a side of has nothing in it to read, and a
            // reader that walked it would report a blank screen. [LAW:no-silent-failure] What
            // a display shows is the pressing rule's, so every reader is handed a region it
            // can read or none. [LAW:single-enforcer]
            guard !rect.isEmpty else { throw NoSuchPlace.empty(rect) }
            guard !layout.active.parts(of: rect).isEmpty else { throw NoSuchPlace.offScreen(rect) }
            return rect
        case .display(let id):
            // The displays `eyes displays` lists, so an id it did not list is refused here.
            guard let display = layout.active.displays.first(where: { $0.id == id }) else { throw NoSuchPlace.display(id) }
            return display.frame
        case .window(let id):
            guard let window = try Geometry.onScreen().windows.first(where: { $0.id == id }) else {
                throw NoSuchPlace.window(id)
            }
            // On a display, as any rectangle must be: a window on a sleeping display is blindness.
            return try Region.rect(window.frame).bounds(on: layout)
        case .front(let front):
            // Its display, as `.display` is refused when asleep or detached; the windows read
            // on it are the front's owners, which each reader takes from its own window list.
            return try Region.display(front.display).bounds(on: layout)
        case .page(let id, let frame):
            // The page goes with its window: a window closed since leaves no page to read.
            guard try Geometry.onScreen().windows.contains(where: { $0.id == id }) else { throw NoSuchPlace.window(id) }
            // On a display, as any rectangle must be: a wait reads it as one from then on.
            return try Region.rect(frame).bounds(on: layout)
        }
    }
}

/// The rectangle a region names on a layout, or a refusal: `Region.bounds` wherever the
/// screen is real.
public typealias Locate = @MainActor @Sendable (Region, DisplayLayout) throws -> ScreenRect

/// One active display, as a caller needs it to aim: the id `Region.display` names, where it
/// sits in the one screen space, and what the window server says of it beyond its place.
public struct Display: Sendable, Hashable {
    public let id: CGDirectDisplayID
    /// Global top-left screen points: negative on a display left of or above the main one.
    public let frame: ScreenRect
    /// The display whose top-left corner is the origin of that space.
    public let isMain: Bool
    /// Backing pixels per point, which is what a capture of it is sized by. Absent when the
    /// display mode could not be read, rather than guessed as 1. [LAW:no-silent-failure]
    public let scale: Double?

    /// `display` of a layout, with what the window server says of it.
    public init(_ display: OnlineDisplay, isMain: Bool, scale: Double?) {
        self.id = display.id
        self.frame = display.frame
        self.isMain = isMain
        self.scale = scale
    }
}

public extension Geometry {
    /// The active displays of `layout`, main first - sorted so, because under mirroring the
    /// display list puts the largest drawable display first, not the main one - each as
    /// `describe` says it. [LAW:one-source-of-truth] The layout is the one list: the displays
    /// `eyes displays` lists are the ones a region is resolved and a row placed on.
    static func displays(in layout: DisplayLayout, describe: (OnlineDisplay) -> Display) -> [Display] {
        layout.active.displays.map(describe).sorted { $0.isMain && !$1.isMain }
    }

    /// A display as the window server says it now: whether it is the main one, and its
    /// backing scale. [LAW:effects-at-boundaries] The one read of either.
    static func describe(_ display: OnlineDisplay) -> Display {
        // Both widths from the mode, which is unrotated; the bounds are rotated, and a
        // portrait display divided by them reads 1.78x instead of 1x.
        let mode = CGDisplayCopyDisplayMode(display.id)
        return Display(display, isMain: CGDisplayIsMain(display.id) != 0,
                       scale: mode.flatMap { $0.width > 0 ? Double($0.pixelWidth) / Double($0.width) : nil })
    }
}

/// A region naming something that is not on screen.
public enum NoSuchPlace: Error, CustomStringConvertible {
    case display(CGDirectDisplayID)
    case window(UInt32)
    case offScreen(ScreenRect)
    case empty(ScreenRect)

    public var description: String {
        switch self {
        case .empty(let r): "\(r) has a side of zero, so there is nothing in it to read"
        case .offScreen(let r): "\(r) is on no active display, so there is nothing there to read"
        case .display(let id): "no active display has id \(id)"
        case .window(let id): "no on-screen window has id \(id); `look` with no arguments, or `eyes windows`, lists the ones that do"
        }
    }
}

public extension Array where Element == Found {
    /// Top to bottom, then left to right, by the part of each run a display shows. Neither
    /// reader's own order is reading order: Vision put a menu's third item after the window
    /// title below it, and the tree walks containers before what they contain. A run belongs
    /// to the line above it while its centre falls inside that line's first run; a fixed
    /// grid split one menu bar in two, because its items do not share a baseline to the point.
    var inReadingOrder: [Found] {
        var lines: [[Found]] = []
        for run in sorted(by: { $0.part.centre.y < $1.part.centre.y }) {
            if let first = lines.last?.first, run.part.centre.y < first.part.maxY {
                lines[lines.count - 1].append(run)
            } else {
                lines.append([run])
            }
        }
        return lines.flatMap { $0.sorted { $0.part.x < $1.part.x } }
    }
}
