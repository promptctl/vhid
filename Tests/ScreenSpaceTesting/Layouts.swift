import ScreenSpace

extension DisplayLayout {
    /// Active displays at `frames`, listed in that order, as the window server would list them.
    public static func at(_ frames: ScreenRect...) -> DisplayLayout {
        try! DisplayLayout(frames.enumerated().map { OnlineDisplay(id: UInt32($0.offset + 1), bounds: $0.element, active: true) })
    }

    /// One display whose edges are further than any test goes, for tests that are not about
    /// the edges.
    public static let vast = at(try! ScreenRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000))
}

extension Displays {
    /// The displays of `DisplayLayout.vast`.
    public static let vast = DisplayLayout.vast.online

    /// `point` placed here, for a test whose points are on these displays.
    public func at(_ point: ScreenPoint) -> Placed<ScreenPoint> { try! place(point) }
}
