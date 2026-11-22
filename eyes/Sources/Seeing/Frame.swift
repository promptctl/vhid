import ScreenSpace

/// Where an element says it is, decided once as it is read: nowhere - it has no position or
/// no size - a box, or numbers an app claimed that are no box, refused by name.
/// [LAW:parse-dont-validate] Every rule after the read asks this, never the numbers again.
public enum Frame: Sendable, Hashable, CustomStringConvertible {
    case none
    case box(ScreenRect)
    case refused(NotABox)

    public var description: String {
        switch self {
        case .none: "(no frame)"
        case .box(let box): "\(box)"
        case .refused(let why): "(no box: \(why))"
        }
    }
}
