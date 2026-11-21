import CoreGraphics
import ScreenSpace

/// The window server's display layout, read in this process's session: the one read both
/// halves make, the daemon's front-session reader for the devices and a look for the
/// readers, so the two place on one layout. [LAW:single-enforcer]
public enum DisplayReading {
    /// The shape of `CGGetOnlineDisplayList` and `CGGetActiveDisplayList`.
    public typealias List = (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    /// More displays than a Mac drives, so a list that fills it may have been cut.
    static let room = 64

    /// Every online display, with whether the active list holds it. Each list is read whole
    /// in one ask: a count asked first and the ids after would drop a display plugged in
    /// between. [LAW:no-silent-failure] A list that filled the room is refused, never taken
    /// as all there are.
    public static func layout(online: List = CGGetOnlineDisplayList, active: List = CGGetActiveDisplayList,
                              bounds: (CGDirectDisplayID) -> CGRect = CGDisplayBounds) throws(LayoutUnreadable) -> DisplayLayout {
        let (onlineIDs, activeIDs) = (try ids(online, "online"), Set(try ids(active, "active")))
        var displays: [OnlineDisplay] = []
        for id in onlineIDs {
            let frame = bounds(id)
            do {
                displays.append(OnlineDisplay(id: id, bounds: try ScreenRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                                              active: activeIDs.contains(id)))
            } catch {
                throw .refused("the window server put display \(id) at \(frame), which is not a box: \(error)")
            }
        }
        return try DisplayLayout(displays)
    }

    private static func ids(_ list: List, _ which: String) throws(LayoutUnreadable) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: room)
        var count: UInt32 = 0
        let error = list(UInt32(room), &ids, &count)
        guard error == .success else { throw .refused("the window server would not list its \(which) displays (CGError \(error.rawValue))") }
        guard Int(count) < room else { throw .refused("the window server listed \(count) \(which) displays, as many as there was room for, so some may be missing") }
        return Array(ids.prefix(Int(count)))
    }
}
