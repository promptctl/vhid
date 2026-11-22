/// One display the window server lists as online: its id, the box of the space it shows,
/// and whether it is active - awake and drawing - or asleep.
///
/// **Online is the devices' list and active the readers'.** The cursor moves on a sleeping
/// display and its Dock still rises, so a press may be made there; a capture shows only
/// what an active display draws, so a reading is placed on those alone. Measured on
/// studious, its one display asleep: the active list was empty and the online list held it
/// at (0, 0, 1600, 900). The members of a mirror set are each online with one frame.
public struct OnlineDisplay: Hashable, Sendable {
    public let id: UInt32
    public let frame: ScreenRect
    public let active: Bool

    public init(id: UInt32, frame: ScreenRect, active: Bool) {
        self.id = id
        self.frame = frame
        self.active = active
    }
}

/// The displays as one read of the window server found them, every online one in its order.
///
/// [LAW:one-source-of-truth] Read once for an act's places and once per pass of a look, and
/// handed down as this value, so every place one act or one pass decides is decided on one
/// layout. A play reads it once more after its last report, to say whether the layout it
/// was placed on still holds.
public struct DisplayLayout: Hashable, Sendable {
    public let displays: [OnlineDisplay]

    /// [LAW:parse-dont-validate] At least one online display, each with an id of its own and
    /// a side of at least a point, all within a box that is finite - which is what lets any
    /// box drawn on them be joined with another without running past a Double; refused by
    /// name otherwise. An empty frame is a read that went wrong, not a display.
    public init(_ displays: [OnlineDisplay]) throws(LayoutUnreadable) {
        guard let first = displays.first else { throw .noDisplay }
        if let empty = displays.first(where: { $0.frame.width < 1 || $0.frame.height < 1 }) { throw .empty(empty.id, empty.frame) }
        var ids = Set<UInt32>()
        if let again = displays.first(where: { !ids.insert($0.id).inserted }) { throw .sameId(again.id) }
        var extent = first.frame
        for display in displays.dropFirst() {
            do { extent = try extent.union(display.frame) } catch { throw .tooWide(error) }
        }
        self.displays = displays
    }

    /// Where a press can be made: every online display.
    public var online: Displays { Displays(displays) }

    /// What a reading can be placed on: the active displays, which may be none.
    public var active: Displays { Displays(displays.filter(\.active)) }

    /// Six numbers a display: its id, left, top, width, height, and 1 for active or 0 for
    /// asleep. The record the front session's reader answers with and the daemon sends a
    /// client, read back by `init(record:)`. [LAW:one-source-of-truth]
    public var record: [Double] {
        displays.flatMap { [Double($0.id), $0.frame.x, $0.frame.y, $0.frame.width, $0.frame.height, $0.active ? 1 : 0] }
    }

    /// The numbers of `record` as a layout, refused by name when they are not one.
    public init(record numbers: [Double]) throws(LayoutUnreadable) {
        guard numbers.count % Self.fields == 0 else { throw .record("\(numbers.count) numbers, not \(Self.fields) to a display") }
        var displays: [OnlineDisplay] = []
        for start in stride(from: 0, to: numbers.count, by: Self.fields) {
            let fields = Array(numbers[start ..< start + Self.fields])
            guard let id = UInt32(exactly: fields[0]) else { throw .record("\(fields[0]) is not a display id") }
            guard fields[5] == 0 || fields[5] == 1 else { throw .record("\(fields[5]) says neither active nor asleep") }
            do {
                displays.append(OnlineDisplay(id: id, frame: try ScreenRect(x: fields[1], y: fields[2], width: fields[3], height: fields[4]), active: fields[5] == 1))
            } catch {
                throw .display(id, error)
            }
        }
        try self.init(displays)
    }

    static let fields = 6
}

/// The displays could not be read as a layout, and why.
public enum LayoutUnreadable: Error, Hashable, CustomStringConvertible {
    /// The window server would not list them, with its error code.
    case windowServer(list: String, code: Int32)
    /// It listed no online display.
    case noDisplay
    /// A display's bounds were not a box.
    case display(UInt32, NotABox)
    /// A display's bounds are a box with a side under a point.
    case empty(UInt32, ScreenRect)
    /// Two displays listed with one id.
    case sameId(UInt32)
    /// The displays together are wider or taller than a Double holds.
    case tooWide(NotABox)
    /// A record that is not one this build reads.
    case record(String)

    public var description: String {
        switch self {
        case .windowServer(let list, let code): "the window server would not list the \(list) displays: CGError \(code)"
        case .noDisplay: "the window server listed no online display"
        case .display(let id, let refused): "display \(id)'s bounds are not a box: \(refused)"
        case .empty(let id, let frame): "display \(id)'s bounds \(frame) have a side under a point"
        case .sameId(let id): "two displays are listed as display \(id)"
        case .tooWide(let refused): "the displays together are not a box: \(refused)"
        case .record(let what): "the display layout record is not one this build reads: \(what)"
        }
    }
}
