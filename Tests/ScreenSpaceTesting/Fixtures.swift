import ScreenSpace

/// Points, boxes and layouts a test writes as numbers it knows to be one: a test that
/// misspells one traps at the line that did, which is the failure it should be.
public extension ScreenPoint {
    static func at(_ x: Double, _ y: Double) -> ScreenPoint { try! ScreenPoint(x: x, y: y) }
}

public extension ScreenRect {
    static func at(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ScreenRect {
        try! ScreenRect(x: x, y: y, width: width, height: height)
    }
}

public extension DisplayLayout {
    /// A display at each frame, in order, ids from 1, each active unless its index is in
    /// `asleep`.
    static func at(_ frames: [ScreenRect], asleep: Set<Int> = []) -> DisplayLayout {
        try! DisplayLayout(frames.enumerated().map { OnlineDisplay(id: UInt32($0.offset + 1), frame: $0.element, active: !asleep.contains($0.offset)) })
    }

    /// One 1920 by 1080 display at the origin, awake.
    static let single = at([.at(0, 0, 1920, 1080)])

    /// A display wider and taller than any path a test draws, so nothing is kept off an edge.
    static let vast = at([.at(-1e6, -1e6, 2e6, 2e6)])
}

public extension Displays {
    /// The vast layout's displays, for tests that are not about the edges.
    static let vast = DisplayLayout.vast.online
}
