import CoreGraphics
import Foundation

/// A window on screen: who owns it and where it is.
///
/// No title. `CGWindowListCopyWindowInfo` returns owner and bounds to any process, and
/// gates the name behind Screen Recording - measured on a Mac without the grant, one
/// window of thirty-two came back named, and `kCGWindowName` was absent from the
/// dictionaries entirely. So this is geometry and owner names, and a reading that
/// promised titles would be empty for almost every window on almost every Mac.
public struct Window: Sendable, Hashable {
    /// The window server's id, which `Region.window` names.
    public let id: UInt32
    /// The application that owns it, which is the only naming available without a grant.
    public let owner: String
    public let frame: ScreenRect

    public init(id: UInt32, owner: String, frame: ScreenRect) {
        self.id = id
        self.owner = owner
        self.frame = frame
    }
}

/// Where the windows are, which is a reading a caller can take before capturing anything.
///
/// [LAW:effects-at-boundaries] The window server call and the rule for reading its answer
/// are held apart, so the rule - which is the part that can be wrong - is exercised
/// against dictionaries a test writes, with no window server and nothing on screen.
public enum Geometry {
    /// The windows a person can actually see, in front-to-back order.
    ///
    /// Needs no grant of any kind.
    @MainActor
    public static func onScreen() throws -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw CannotReadWindows()
        }
        return windows(from: raw)
    }

    /// The rule, alone. [LAW:decomposition]
    ///
    /// Three quarters of what the window server hands back is not a window anyone means.
    /// Measured on one Mac at one moment: thirty-two entries, of which eleven were
    /// applications. The rest were the menu bar, thirteen Control Center items, and three
    /// Notification Center surfaces - and on another reading of the same Mac, a
    /// `loginwindow` entry 30000 by 30000 points at a negative origin.
    ///
    /// The layer is what separates them, because it is the window server's own answer to
    /// the question rather than a guess from size or owner: applications compose at layer
    /// zero, the menu bar sits at 24, its extras at 25, and Notification Center far below
    /// at Int32.min. A size threshold would be this module inventing a rule the system
    /// already publishes, and would drop a small real palette while keeping a large fake
    /// one. [LAW:one-source-of-truth]
    static func windows(from raw: [[String: Any]]) -> [Window] {
        raw.compactMap { entry in
            guard entry[kCGWindowLayer as String] as? Int == 0 else { return nil }
            // A window composited at zero alpha is on the list and on no screen.
            guard (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = Self.rect(from: bounds),
                  !rect.isEmpty
            else { return nil }
            return Window(id: id, owner: owner, frame: rect)
        }
    }

    /// The bounds dictionary as the window server writes it: X, Y, Width, Height, already
    /// in global screen coordinates with a top-left origin, which is the space everything
    /// here answers in. Nothing is converted; a missing field is refused rather than
    /// defaulted to zero, because a window at 0,0 sized 0 is a lie about a window whose
    /// position was not readable. [LAW:no-silent-failure]
    private static func rect(from bounds: [String: Any]) -> ScreenRect? {
        guard let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
        else { return nil }
        return ScreenRect(x: x, y: y, width: width, height: height)
    }
}

public struct CannotReadWindows: Error, CustomStringConvertible {
    public var description: String { "the window server would not list its windows" }
}
