import CoreGraphics
import Foundation

/// The online displays, each where it sits in `ScreenPoint`'s space and whether it is active:
/// the one layout both halves read. [LAW:one-source-of-truth]
///
/// **Online, not active.** A display gone to sleep is not active, and the cursor still moves on
/// it and its Dock still rises: measured on studious, its one display asleep, the active list
/// was empty and the online list held it at 0,0,1600,900. So the devices place against every
/// display here; a capture shows only an active one, so the readers read those. The members of
/// a mirror set are all online with one frame, which only says that frame twice.
///
/// [LAW:parse-dont-validate] A layout that exists has at least one display, every display's
/// bounds a box, and an extent - the box holding them all - that is a box too and whose
/// diagonal is a finite number, so every difference of two points inside it, and the distance
/// between them, is a finite number. The layout is the only bound the space has.
public struct DisplayLayout: Sendable, Equatable {
    public let displays: [Display]
    /// The smallest box holding every display.
    public let extent: ScreenRect

    public struct Display: Sendable, Equatable {
        public let id: CGDirectDisplayID
        /// Global top-left screen points: negative on a display left of or above the main one.
        /// A display with no area is kept, and shows nothing.
        public let bounds: ScreenRect
        public let isActive: Bool
    }

    /// The displays that show what a capture can: the active ones.
    public var active: [Display] { displays.filter(\.isActive) }

    /// The layout `online` reads: each display's bounds parsed as a box, refused by the display
    /// and the bounds it gave when they are none. [LAW:no-silent-failure] Takes the readings as
    /// values, so it is tested with no window server. [LAW:effects-at-boundaries]
    public init(_ online: [OnlineDisplay]) throws(LayoutUnreadable) {
        var displays: [Display] = []
        for display in online {
            guard let bounds = try? ScreenRect(display.bounds) else { throw .bounds(display: display.id, display.bounds) }
            displays.append(Display(id: display.id, bounds: bounds, isActive: display.isActive))
        }
        guard let first = displays.first else { throw .noDisplay }
        guard let extent = first.bounds.union(displays.dropFirst().map(\.bounds)), hypot(extent.width, extent.height).isFinite
        else { throw .noExtent(displays.map(\.bounds)) }
        self.displays = displays
        self.extent = extent
    }

    /// The layout as the window server has it now.
    public static func read() throws(LayoutUnreadable) -> DisplayLayout { try DisplayLayout(online()) }

    /// The shape of `CGGetOnlineDisplayList`: room for so many ids, where to put them, and how
    /// many there are.
    public typealias DisplayList = (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    /// Every online display as the window server gives it. A list it would not give is said,
    /// never taken for no display online. [LAW:no-silent-failure] `list` is the window server's
    /// `CGGetOnlineDisplayList`, or a test's.
    public static func online(list: DisplayList = CGGetOnlineDisplayList) throws(LayoutUnreadable) -> [OnlineDisplay] {
        var count: UInt32 = 0
        var error = list(0, nil, &count)
        guard error == .success else { throw .list(error) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        error = list(count, &ids, &count)
        guard error == .success else { throw .list(error) }
        return ids.prefix(Int(count)).map { OnlineDisplay(id: $0, bounds: CGDisplayBounds($0), isActive: CGDisplayIsActive($0) != 0) }
    }
}

/// One online display as the window server read it: what a `DisplayLayout` is parsed from.
public struct OnlineDisplay: Sendable, Equatable {
    public let id: CGDirectDisplayID
    public let bounds: CGRect
    public let isActive: Bool

    public init(id: CGDirectDisplayID, bounds: CGRect, isActive: Bool) {
        self.id = id
        self.bounds = bounds
        self.isActive = isActive
    }
}

/// A display layout that could not be read or is no layout.
public enum LayoutUnreadable: Error, Equatable, CustomStringConvertible {
    /// The window server would not list the displays.
    case list(CGError)
    /// A display's bounds are no box.
    case bounds(display: CGDirectDisplayID, CGRect)
    /// No display is online.
    case noDisplay
    /// The displays lie further apart than a Double spans.
    case noExtent([ScreenRect])

    public var description: String {
        switch self {
        case .list(let error):
            "the window server would not list its displays (CGError \(error.rawValue))"
        case .bounds(let id, let raw):
            "display \(id) has bounds \([raw.origin.x, raw.origin.y, raw.size.width, raw.size.height].map { Coordinate.spelled(Double($0)) }.joined(separator: ",")), which are no box on the screen"
        case .noDisplay:
            "no display is online"
        case .noExtent(let bounds):
            "the displays \(bounds.map { "\($0)" }.joined(separator: "; ")) lie further apart than one screen space spans"
        }
    }
}
