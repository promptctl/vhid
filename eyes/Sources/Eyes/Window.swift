import CoreGraphics
import Foundation

/// A window on screen: who owns it, where it is, and how high it is composited.
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
    ///
    /// Absent when the owning process has no application name. `kCGWindowOwnerName` is in
    /// Apple's *optional* key group - unlike the id, the layer and the bounds, which are
    /// required - so a window can be perfectly visible and perfectly clickable while
    /// having nothing to call it by. Optional rather than dropped: a name is the one
    /// thing here a caller does not need in order to click, and refusing the window over
    /// it would be the layer rule's mistake again in miniature.
    public let owner: String?
    public let frame: ScreenRect
    /// Where the window server composites it, which is `NSWindow.Level` by another name -
    /// measured, not assumed: a window set to `.modalPanel` comes back at 8, `.floating`
    /// at 3, `.popUpMenu` at 101.
    ///
    /// Carried rather than filtered on, because it is the one fact that tells an open
    /// menu apart from an ordinary window and this module is not the place that decides
    /// which of those a caller meant. [LAW:dataflow-not-control-flow]
    public let layer: Int

    public init(id: UInt32, owner: String?, frame: ScreenRect, layer: Int) {
        self.id = id
        self.owner = owner
        self.frame = frame
        self.layer = layer
    }
}

/// Every window on screen, and a count of what the window server listed that is not one.
///
/// [LAW:no-silent-failure] The count is the point. A reading that hands back twelve
/// windows out of twenty-seven entries and says nothing about the other fifteen is a
/// narrow answer with no way to tell it from a whole one.
public struct WindowListing: Sendable, Hashable {
    /// In the window server's own front-to-back order, which is preserved because the
    /// first row being the frontmost window is most of what makes this useful.
    public let windows: [Window]
    /// What was left out, by why. Empty when nothing was.
    public let excluded: [WindowExclusion]

    public init(windows: [Window], excluded: [WindowExclusion]) {
        self.windows = windows
        self.excluded = excluded
    }

    /// What the window server listed *as on screen*, derived rather than carried so it
    /// cannot disagree with the two numbers it is the sum of. [LAW:one-source-of-truth]
    ///
    /// Not every window that exists. The reading asks for on-screen windows only, and
    /// measured on one Mac at one moment that is 29 entries where asking for all of them
    /// returns 110 - the rest being minimized, hidden, and other spaces. That narrowing
    /// happens before any of this and cannot be counted here, which is exactly why the
    /// binary's scope line says it in words instead.
    public var listed: Int { windows.count + excluded.reduce(0) { $0 + $1.count } }
}

/// Entries the window server listed that are not a window anyone can see or click.
public struct WindowExclusion: Sendable, Hashable {
    public let reason: Reason
    public let count: Int

    public init(reason: Reason, count: Int) {
        self.reason = reason
        self.count = count
    }

    public enum Reason: String, Sendable, Hashable {
        /// Composited at zero alpha: on the list and on no screen.
        case invisible
        /// Zero-sized, so there is nowhere in it to look and nothing in it to click.
        case arealess
        /// The entry did not describe a window: no id, no owner, no layer, or bounds that
        /// would not read as four finite numbers. Kept apart from the other two because
        /// this one is an anomaly rather than an ordinary invisible surface, and a caller
        /// seeing it climb is seeing something wrong.
        ///
        /// Not spelled `unplaced`, which `Exclusion.Reason` already uses for a candidate
        /// that is zero-sized or outside the region - an ordinary, expected narrowing. A
        /// caller reads a `WindowListing` and a `Reading` in the same breath, since
        /// `Region.window` takes an id from the first and hands it to the second, and one
        /// word meaning "nothing unusual" in one and "something is wrong" in the other is
        /// the one word that would not carry across. [LAW:one-source-of-truth]
        case unreadable
    }
}

/// Where the windows are, which is a reading a caller can take before capturing anything.
///
/// [LAW:effects-at-boundaries] The window server call and the rule for reading its answer
/// are held apart, so the rule - which is the part that can be wrong - is exercised
/// against dictionaries a test writes, with no window server and nothing on screen.
public enum Geometry {
    /// The windows a person can see, in front-to-back order.
    ///
    /// Needs no grant of any kind.
    ///
    /// **On screen means on screen.** A minimized window, a window on another Space, and
    /// a hidden application's windows are not in this answer and are not counted in
    /// `listed` either - the window server filters them before this function sees
    /// anything, so there is nothing here to count them with. Measured on one Mac at one
    /// moment: 29 on screen against 110 in all. A caller asking "is there a Safari
    /// window" and meaning "even a minimized one" is asking a different question than
    /// this one answers, which is why every caller of this is expected to say so - the
    /// binary above prints it in the scope line. [LAW:no-silent-failure]
    @MainActor
    public static func onScreen() throws -> WindowListing {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw CannotReadWindows()
        }
        return listing(from: raw)
    }

    /// The rule, alone. [LAW:decomposition]
    ///
    /// It keeps every surface that is actually on screen and says how high each one sits,
    /// rather than deciding which heights a caller meant.
    ///
    /// **Why there is no layer filter here.** An earlier rule kept only layer zero, which
    /// reads as "ordinary application windows" and is measured to drop an open menu (101),
    /// a modal alert panel (8) and a floating palette (3) - the transient surfaces a
    /// caller driving a pointer most needs to find, gone with no trace. The repair is not
    /// a longer list of allowed layers, because the layers do not separate: the Dock sits
    /// at 20 and the menu bar at 24, *between* an app's modal panel at 8 and its menus at
    /// 101. No threshold divides application content from system chrome, so any list of
    /// numbers here would be this module inventing a rule the window server does not
    /// publish - the same mistake as ranking windows by size. [LAW:one-source-of-truth]
    ///
    /// So the layer travels to the caller as a value, and what is dropped is only what is
    /// not a surface at all. [LAW:dataflow-not-control-flow]
    static func listing(from raw: [[String: Any]]) -> WindowListing {
        var windows: [Window] = []
        var counts: [WindowExclusion.Reason: Int] = [:]

        for entry in raw {
            // The owner name is deliberately not in this guard: it is an optional key,
            // so a window with no application name is an ordinary window rather than a
            // malformed entry, and counting it as an anomaly would fire `unreadable` for
            // a documented-normal shape while dropping something a caller can click.
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = Self.rect(from: bounds)
            else {
                counts[.unreadable, default: 0] += 1
                continue
            }
            let owner = entry[kCGWindowOwnerName as String] as? String
            guard (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0 else {
                counts[.invisible, default: 0] += 1
                continue
            }
            guard !rect.isEmpty else {
                counts[.arealess, default: 0] += 1
                continue
            }
            windows.append(Window(id: id, owner: owner, frame: rect, layer: layer))
        }

        // Ordered by the reason's own spelling so the same screen always reports its
        // exclusions in the same order, rather than in whatever order a dictionary
        // happened to hash them. [LAW:no-ambient-temporal-coupling]
        let excluded = counts
            .map { WindowExclusion(reason: $0.key, count: $0.value) }
            .sorted { $0.reason.rawValue < $1.reason.rawValue }
        return WindowListing(windows: windows, excluded: excluded)
    }

    /// The bounds dictionary as the window server writes it: X, Y, Width, Height, already
    /// in global screen coordinates with a top-left origin, which is the space everything
    /// here answers in. Nothing is converted; a missing field is refused rather than
    /// defaulted to zero, because a window at 0,0 sized 0 is a lie about a window whose
    /// position was not readable. [LAW:no-silent-failure]
    ///
    /// [LAW:parse-dont-validate] This is the one door the window server's numbers come
    /// through, so finiteness is established here and never asked about again. NaN
    /// reaches it - `as? Double` bridges an `NSNumber` holding one without complaint -
    /// and then passes every check downstream that looks like it would catch it: `NaN <=
    /// 0` is false, so a NaN-sized window is not `isEmpty` and is kept, and the first
    /// thing that touches it traps outright, because `Int(Double.nan)` is a fatal error
    /// rather than a bad number. A window whose bounds are not numbers is an entry that
    /// did not describe a window, which is what the `unreadable` count is for.
    private static func rect(from bounds: [String: Any]) -> ScreenRect? {
        guard let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite
        else { return nil }
        return ScreenRect(x: x, y: y, width: width, height: height)
    }
}

public struct CannotReadWindows: Error, CustomStringConvertible {
    public var description: String { "the window server would not list its windows" }
}
