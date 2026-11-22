import ScreenSpace

/// Where an element is, as its app said it, decided once as it is read.
///
/// [LAW:types-are-the-program] Three answers, so no reader of a frame decides alone what a
/// frame that is no box means: each says what it does with a refusal, by name.
public enum Frame: Sendable, Hashable, CustomStringConvertible {
    /// It has no position or no size.
    case none
    case box(ScreenRect)
    /// What the app gave is no box: a number not finite, a side under zero, or a far edge
    /// past what a Double holds.
    case refused(NotABox)

    /// The box, where the app gave one.
    public var box: ScreenRect? {
        if case .box(let box) = self { box } else { nil }
    }

    public var description: String {
        switch self {
        case .none: "(no frame)"
        case .box(let box): box.description
        case .refused(let refused): "(\(refused))"
        }
    }
}
