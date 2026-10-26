/// Where a click at a point lands, by the system's own hit test: the app and window it goes
/// to, and the element it presses with the elements it sits in, up to the area holding them.
///
/// A question a caller asks before an act, never a guard on one: eyes decides nothing on it.
public struct Landing: Sendable, Equatable {
    public let point: ScreenPoint
    /// The app of the element hit.
    public let app: Front.App
    /// Whether a look with no place named reads that app. [LAW:one-source-of-truth]
    public let standing: Standing
    /// The frontmost listed window of the app holding the point, nil when none of its listed
    /// windows does - a panel the window server lists under another process, or none at all.
    public let window: Window?
    /// The element hit, then each parent, nearest first.
    public let elements: [Element]
    public let end: End
    /// The hit tests and reads the climb made.
    public let calls: Int
    /// The hit tests the front look's rule made, to say where the app stands.
    public let frontCalls: Int

    public init(point: ScreenPoint, app: Front.App, standing: Standing, window: Window?, elements: [Element], end: End, calls: Int,
                frontCalls: Int) {
        self.point = point
        self.app = app
        self.standing = standing
        self.window = window
        self.elements = elements
        self.end = end
        self.calls = calls
        self.frontCalls = frontCalls
    }

    /// One element as it says itself: its role, the value, title and description it answered
    /// that are not blank, in that order, how many of those three would not say, and its frame,
    /// nil without a position or a size.
    public struct Element: Sendable, Hashable {
        public let role: Role
        public let texts: [String]
        public let unanswered: Int
        public let frame: ScreenRect?

        public init(role: Role, texts: [String], unanswered: Int = 0, frame: ScreenRect?) {
            self.role = role
            self.texts = texts
            self.unanswered = unanswered
            self.frame = frame
        }
    }

    /// How a climb from the element hit ended.
    public enum End: Sendable, Hashable {
        /// At an area - a window, a list, a toolbar, a web page: what holds the elements below
        /// it, which says where a click lands, not what it presses.
        case area
        /// At the top of the element's tree, with no area on the way.
        case top
        /// Past `Probe.depth` parents, every one of which answered: parents that run in a loop.
        case tooDeep
        /// Before either, so the elements above the last one listed were never read.
        case short(Short)

        public var said: String {
            switch self {
            case .area: "area"
            case .top: "top"
            case .tooDeep: "too_deep"
            case .short(let why): why.rawValue
            }
        }
    }

    /// What the tree's climb from the element hit says, before the window server is asked
    /// which app and window that is: the process of the element hit - not a second hit test,
    /// which could land on something else - and what the climb read.
    public struct Climb: Sendable, Equatable {
        public let pid: Int32
        public let elements: [Element]
        public let end: End
        public let calls: Int

        public init(pid: Int32, elements: [Element], end: End, calls: Int) {
            self.pid = pid
            self.elements = elements
            self.end = end
            self.calls = calls
        }
    }

    /// Why a climb stopped short of an area or the top.
    public enum Short: String, Sendable, Hashable {
        /// A hit test or a read did not answer.
        case unanswered
        /// The time for hit tests ran out first.
        case overTime = "over_time"
    }
}

/// What the tree's hit test at a point answered, when it answered: no element there, with the
/// calls that took, or the climb from the element hit.
public enum Landed: Sendable, Equatable {
    case nothing(calls: Int)
    case on(Landing.Climb)
}

/// What `eyes hit` answers of a point it heard back about.
public enum Struck: Sendable, Equatable {
    /// No element answers there; the window listed frontmost at the point, which a click lands
    /// in all the same, nil when none is - an app that exposes nothing, a game, a canvas.
    case nothing(calls: Int, window: Window?)
    case landed(Landing)
}

/// The hit test at a point gave no element to climb from: it did not answer, or the time ran
/// out before it could be asked. An error, not an empty landing: nothing is known about what
/// is there. [LAW:no-silent-failure]
public struct HitUnheard: Error, Equatable, CustomStringConvertible {
    public let point: ScreenPoint
    public let why: Landing.Short
    /// The calls made before it gave up.
    public let calls: Int

    public init(point: ScreenPoint, why: Landing.Short, calls: Int) {
        self.point = point
        self.why = why
        self.calls = calls
    }

    public var description: String {
        switch why {
        case .unanswered: "the system's hit test at \(point), or the app it hit asked which it is, did not answer, so what a click there would hit is unknown"
        case .overTime: "the time for hit tests ran out before the one at \(point), so what a click there would hit is unknown"
        }
    }
}
