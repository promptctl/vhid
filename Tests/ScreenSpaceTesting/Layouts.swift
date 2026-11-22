import ScreenSpace

extension DisplayLayout {
    /// Displays at `frames`, listed in that order with ids from 1 as the window server would
    /// list them, active but for the ids in `asleep`.
    public static func at(_ frames: ScreenRect..., asleep: Set<UInt32> = []) -> DisplayLayout {
        try! DisplayLayout(frames.enumerated().map { index, frame in
            let id = UInt32(index + 1)
            return OnlineDisplay(id: id, bounds: frame, active: !asleep.contains(id))
        })
    }

    /// One display whose edges are further than any test goes, for tests that are not about
    /// the edges.
    public static let vast = at(try! ScreenRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000))

    /// The main display, and one above and right of it asleep: what a wire carries a
    /// sleeping display across as.
    public static let besideOneAsleep = at(try! ScreenRect(x: 0, y: 0, width: 1920, height: 1080),
                                           try! ScreenRect(x: 1920, y: -200, width: 1280, height: 800), asleep: [2])
}

extension Displays {
    /// The displays of `DisplayLayout.vast`.
    public static let vast = DisplayLayout.vast.online

    /// `point` placed here, for a test whose points are on these displays.
    public func at(_ point: ScreenPoint) -> Placed<ScreenPoint> { try! place(point) }
}
