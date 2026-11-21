import CoreGraphics
import ScreenSpace

/// The display layout as the window server has it now: the one read of it, for the processes
/// that read it in the session they draw in - the daemon's front-session reader, the recorder
/// and eyes. [LAW:effects-at-boundaries] Its own target, so what only parses a layout links no
/// window server.
public extension DisplayLayout {
    static func read() throws(LayoutUnreadable) -> DisplayLayout { try DisplayLayout(OnlineDisplay.read()) }
}

public extension OnlineDisplay {
    /// The shape of `CGGetOnlineDisplayList` and `CGGetActiveDisplayList`: room for so many
    /// ids, where to put them, and how many there are.
    typealias DisplayList = (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    /// Every online display, active when the active list holds it. Active is that list's word
    /// rather than `CGDisplayIsActive`'s, since what a capture shows is what it lists.
    /// [LAW:one-source-of-truth] A list the window server would not give is said, never taken
    /// for no display. [LAW:no-silent-failure] `online` and `active` are the window server's
    /// lists, or a test's.
    static func read(online: DisplayList = CGGetOnlineDisplayList, active: DisplayList = CGGetActiveDisplayList) throws(LayoutUnreadable) -> [OnlineDisplay] {
        let drawn = Set(try ids(active))
        return try ids(online).map { OnlineDisplay(id: $0, bounds: CGDisplayBounds($0), isActive: drawn.contains($0)) }
    }

    private static func ids(_ list: DisplayList) throws(LayoutUnreadable) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var error = list(0, nil, &count)
        guard error == .success else { throw .list(error) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        error = list(count, &ids, &count)
        guard error == .success else { throw .list(error) }
        return Array(ids.prefix(Int(count)))
    }
}
