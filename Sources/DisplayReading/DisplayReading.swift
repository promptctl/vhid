import CoreGraphics
import ScreenSpace

/// The shape of `CGGetOnlineDisplayList` and `CGGetActiveDisplayList`: room for so many ids,
/// where to put them, and how many there are.
typealias DisplayList = (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

public extension DisplayLayout {
    /// The displays as the window server lists them now, in this process's session: every
    /// online one, each marked active or asleep. [LAW:effects-at-boundaries] The one read of
    /// the layout; the daemon's reader in the session in front, the readers and the recorder
    /// all read it here.
    static func read() throws(LayoutUnreadable) -> DisplayLayout {
        let online = try list("online", CGGetOnlineDisplayList)
        let active = Set(try list("active", CGGetActiveDisplayList))
        var displays: [OnlineDisplay] = []
        for id in online {
            do {
                displays.append(OnlineDisplay(id: id, frame: try ScreenRect(CGDisplayBounds(id)), active: active.contains(id)))
            } catch {
                throw .display(id, error)
            }
        }
        return try DisplayLayout(displays)
    }

    /// One display list, read whole: asked with room for one more than it last held, until
    /// it holds less than the room, so a display that came online between the count and the
    /// list is not cut off it. A list the window server would not give is said, at either
    /// ask, and never read as no display. [LAW:no-silent-failure]
    internal static func list(_ name: String, _ read: DisplayList) throws(LayoutUnreadable) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let counted = read(0, nil, &count)
        guard counted == .success else { throw .windowServer(list: name, code: counted.rawValue) }
        while true {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count) + 1)
            var listed: UInt32 = 0
            let answered = read(UInt32(ids.count), &ids, &listed)
            guard answered == .success else { throw .windowServer(list: name, code: answered.rawValue) }
            guard listed == ids.count else { return Array(ids.prefix(Int(listed))) }
            count = listed
        }
    }
}
