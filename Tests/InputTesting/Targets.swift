import Input
import ScreenSpace
import ScreenSpaceTesting

/// Targets placed by the one rule, as a verb places them, on the vast layout unless a test
/// names its own: a test that places one no display shows traps at the line that did.
public extension Target {
    static func point(_ point: ScreenPoint, on displays: Displays = .vast) -> Target {
        .point(try! displays.place(point))
    }

    static func box(_ box: ScreenRect, on displays: Displays = .vast) -> Target {
        .box(try! displays.place(box))
    }
}

public extension Placed<ScreenPoint> {
    /// `point` placed on `displays`, the vast layout unless a test names its own.
    static func on(_ point: ScreenPoint, _ displays: Displays = .vast) -> Placed<ScreenPoint> {
        try! displays.place(point)
    }
}
