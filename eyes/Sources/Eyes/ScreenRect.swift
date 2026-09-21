import CoreGraphics

/// A rectangle in the one coordinate space every reader answers in: global screen
/// coordinates, top-left origin, points.
///
/// [LAW:types-are-the-program] A named type rather than a bare `CGRect`, because the
/// failure this exists to prevent is one a `CGRect` cannot be checked for. Vision hands
/// back normalized boxes in image space with the origin at the bottom-left; a display has
/// a backing scale factor; a second display sits at its own origin in the global space,
/// which is often negative. A reader that misses the flip, or the scale, or the display
/// origin produces numbers that are still four plausible Doubles in the right order of
/// magnitude, and clicking one lands somewhere else entirely. Nothing downstream can tell
/// the two apart, so the conversion has to be the only door into this type rather than a
/// step a reader is trusted to have taken.
///
/// The space is not a choice made here. It is the space `vhid click` consumes and the
/// space the accessibility tree already answers in, so the centre of one of these is a
/// click's target with no conversion at all. [LAW:one-source-of-truth]
public struct ScreenRect: Sendable, Hashable {
    /// Leftmost point, increasing to the right. Negative on a display left of the main one.
    public let x: Double
    /// Topmost point, increasing DOWNWARD. This is the axis that gets flipped by mistake.
    public let y: Double
    public let width: Double
    public let height: Double

    /// For a reader that already holds global, top-left, point coordinates - which the
    /// accessibility tree does, and pixels do not.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Where a caller clicks to hit this, which is the only reason any of this is
    /// measured. [LAW:one-source-of-truth] Derived rather than carried, so it cannot
    /// disagree with the rectangle it came from.
    public var centre: ScreenPoint { ScreenPoint(x: x + width / 2, y: y + height / 2) }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height
    }

    /// Whether any part of the two overlap, which is how a merged reading tells one thing
    /// seen twice from two things seen once.
    public func intersects(_ other: ScreenRect) -> Bool {
        x < other.x + other.width && other.x < x + width
            && y < other.y + other.height && other.y < y + height
    }
}

/// A point in the same space, top-left origin, points.
public struct ScreenPoint: Sendable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public extension ScreenRect {
    /// The one door from image space into screen space, and the only place the flip and
    /// the display origin are applied. [LAW:single-enforcer] Every reader that starts
    /// from pixels comes through here, so there is one implementation to get right and
    /// one to test rather than one per reader.
    ///
    /// **The backing scale factor does not appear, and that is the point.** A normalized
    /// box is a fraction of the image, and the same fraction of the display's point size,
    /// so the pixels divide out before anything here runs: a 2x capture and a 1x capture
    /// of the same screen produce the same answer. The scale can only be gotten wrong by
    /// a reader that converts to pixels first, which is why nothing here takes a pixel
    /// size - a value nobody passes is a value nobody can pass wrongly.
    /// [LAW:types-are-the-program]
    ///
    /// - Parameters:
    ///   - normalized: the box as Vision reports it - a unit rectangle whose origin is at
    ///     the BOTTOM-left of the image.
    ///   - display: where the captured display sits in the global space, top-left origin,
    ///     in points. Often at a negative origin when it is not the main one.
    static func fromImageSpace(normalized: CGRect, on display: ScreenRect) -> ScreenRect {
        let left = display.x + normalized.origin.x * display.width
        // The flip. Vision measures up from the bottom of the image; the screen measures
        // down from the top. A box's TOP edge is therefore its distance from the bottom
        // plus its own height, taken away from the whole.
        let top = display.y + (1 - normalized.origin.y - normalized.height) * display.height
        return ScreenRect(
            x: left,
            y: top,
            width: normalized.width * display.width,
            height: normalized.height * display.height
        )
    }
}
