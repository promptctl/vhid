import CoreGraphics
import Foundation

/// The online displays, each where it sits in `ScreenPoint`'s space and whether it is active:
/// the one layout both halves read. [LAW:one-source-of-truth]
///
/// **Online, not active.** A display gone to sleep is not active, and the cursor still moves on
/// it and its Dock still rises: measured on studious, its one display asleep, the active list
/// was empty and the online list held it at 0,0,1600,900. So the devices place against every
/// display here; a capture shows only an active one, so the readers read those. The members of
/// a mirror set are all online with one frame, which only says that frame twice; only the
/// set's primary is active.
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

    /// The layout the window server's readings make: each display's bounds parsed as a box,
    /// refused by the display and the refusal of its bounds when they are none.
    /// [LAW:no-silent-failure] Takes the readings as values, so it is tested with no window
    /// server; `DisplayReading` reads them. [LAW:effects-at-boundaries]
    public init(_ online: [OnlineDisplay]) throws(LayoutUnreadable) {
        var displays: [Display] = []
        for display in online {
            let bounds: ScreenRect
            do { bounds = try ScreenRect(display.bounds) } catch { throw .bounds(display: display.id, error) }
            displays.append(Display(id: display.id, bounds: bounds, isActive: display.isActive))
        }
        guard let first = displays.first else { throw .noDisplay }
        guard let extent = first.bounds.union(displays.dropFirst().map(\.bounds)), hypot(extent.width, extent.height).isFinite
        else { throw .noExtent(displays.map(\.bounds)) }
        self.displays = displays
        self.extent = extent
    }

}

/// One online display as the window server read it: what a `DisplayLayout` is parsed from.
public struct OnlineDisplay: Sendable, Equatable {
    public let id: CGDirectDisplayID
    public let bounds: CGRect
    /// Whether the window server lists it active, drawn on and so captured: not a sleeping
    /// display, nor a hardware mirror set's members past its primary.
    public let isActive: Bool

    public init(id: CGDirectDisplayID, bounds: CGRect, isActive: Bool) {
        self.id = id
        self.bounds = bounds
        self.isActive = isActive
    }

    /// The six numbers a display crosses a wire as: its id, its bounds as given - never
    /// standardized, so the side that parses them refuses bounds that are no box - and 1 when
    /// it is active, 0 when not. [LAW:one-source-of-truth] The one record both wires carry,
    /// the screen reader's lines and the helper connection's numbers.
    public var record: [Double] {
        [Double(id), bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height, isActive ? 1 : 0]
    }

    /// How many numbers a `record` is, for a wire that carries records end to end.
    public static let recordLength = 6

    /// A display read back from its `record`, or nil for numbers that are not one: not
    /// `recordLength` of them, an id that is not one, or an active flag that is neither 0 nor 1.
    /// [LAW:parse-dont-validate]
    public init?(record: some Collection<Double>) {
        let fields = Array(record)
        guard fields.count == Self.recordLength, let id = CGDirectDisplayID(exactly: fields[0]), [0, 1].contains(fields[5]) else { return nil }
        self.init(id: id, bounds: CGRect(x: fields[1], y: fields[2], width: fields[3], height: fields[4]), isActive: fields[5] == 1)
    }
}

/// A display layout that could not be read or is no layout.
public enum LayoutUnreadable: Error, Equatable, CustomStringConvertible {
    /// The window server would not list the displays, online or active.
    case list(CGError)
    /// A display's bounds are no box.
    case bounds(display: CGDirectDisplayID, NotABox)
    /// No display is online.
    case noDisplay
    /// The displays lie further apart than a Double spans.
    case noExtent([ScreenRect])

    public var description: String {
        switch self {
        case .list(let error):
            "the window server would not list its displays (CGError \(error.rawValue))"
        case .bounds(let id, let refused):
            "display \(id)'s bounds: \(refused)"
        case .noDisplay:
            "no display is online"
        case .noExtent(let bounds):
            "the displays \(bounds.map { "\($0)" }.joined(separator: "; ")) lie further apart than one screen space spans"
        }
    }
}
