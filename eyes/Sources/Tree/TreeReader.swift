import ApplicationServices
import Eyes

/// Reads the screen through the accessibility tree: every on-screen window in the region,
/// walked element by element, each element that says something reported at its own
/// frame with its role.
///
/// The windows are the region's, not a separate argument, so the tree and the pixels
/// answer the same `Query` about the same place, and a merged reader hands one query to
/// both. [LAW:composability] Windows and not whole apps, measured: an app's tree also
/// holds its minimized windows and a menu bar that reports a frame at the top of the
/// screen whether or not it is showing, and walking a browser behind the window asked
/// about spent the whole time bound before reaching it.
///
/// Everything here is the edge - the grant and the reads. What an element becomes is
/// `Facts.candidate`, how the tree is walked is `walk`, and what matches is
/// `Reading.judging`. [LAW:effects-at-boundaries]
public struct TreeReader: Reader {
    public let source = SourceKind.tree

    /// Well above the few hundred elements a window of native controls has, and well below
    /// a browser page's tens of thousands.
    static let bounds = Bounds(elements: Limit(4000)!, time: .seconds(5))

    /// A read is a synchronous call into another process, and at the system default one
    /// busy app can hold a single read for many seconds - past the whole walk's time bound,
    /// which is checked only between reads. Half a second is far above the 10-35 ms an
    /// answer takes and far below that bound. Set on every element, because a child does
    /// not inherit its parent's.
    static let messagingTimeout: Float = 0.5

    public init() {}

    public func read(_ query: Query) async throws -> Reading {
        // [LAW:no-silent-failure] Asked first: without the grant, every read fails, and a
        // walk that counted them as unanswered would report a looked-at, empty screen.
        guard AXIsProcessTrusted() else { throw TreeError.noGrant }
        let region = try query.region.bounds()
        let (roots, unanswered) = try Self.roots(meeting: region, in: Geometry.onScreen().windows)
        let clock = ContinuousClock()
        let start = clock.now
        let walked = try walk(
            from: roots,
            unansweredRoots: unanswered,
            in: region,
            within: Self.bounds,
            elapsed: { clock.now - start },
            read: Self.node
        )
        return Reading.judging(
            walked.found.inReadingOrder,
            query: query,
            region: region,
            examined: walked.examined,
            excluded: walked.excluded,
            reach: walked.reach
        )
    }

    /// The accessibility window for each on-screen window meeting `region`, front to back,
    /// each with the frames of every window in front of it - every layer, so the menu bar
    /// and the Dock cover what they cover.
    ///
    /// The window server and the accessibility tree share no public id, so a window is
    /// matched by its owner and its frame, which both answer in the same points. Frames
    /// repeat - measured, a terminal listed three accessibility windows at one full-screen
    /// frame, two of them tabs on no screen - so each accessibility window is claimed once,
    /// by the frontmost on-screen window it matches, and an app lists its windows front to
    /// back. An app that will not list its windows is counted, not skipped.
    /// [LAW:no-silent-failure]
    static func roots(meeting region: ScreenRect, in windows: [Window]) throws(TreeError) -> ([Root<AXUIElement>], Int) {
        var listed: [Int32: Heard<[(AXUIElement, ScreenRect?)]>] = [:]
        var roots: [Root<AXUIElement>] = []
        var unanswered = 0
        for (index, window) in windows.enumerated() where window.frame.intersects(region) {
            if listed[window.pid] == nil {
                listed[window.pid] = try Self.windows(of: window.pid)
                if case .unanswered = listed[window.pid] { unanswered += 1 }
            }
            guard case .answered(var candidates) = listed[window.pid],
                  let claimed = candidates.firstIndex(where: { $0.1.map { same($0, window.frame) } ?? false })
            else { continue }
            roots.append(Root(element: candidates.remove(at: claimed).0, covers: windows[..<index].map(\.frame)))
            listed[window.pid] = .answered(candidates)
        }
        return (roots, unanswered)
    }

    /// Frames agree to the point; the two sources round differently below that.
    private static func same(_ a: ScreenRect, _ b: ScreenRect) -> Bool {
        abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// An app's windows and where each is. A window that will not say where it is has no
    /// frame and matches nothing - it is not on screen as far as this can tell.
    private static func windows(of pid: Int32) throws(TreeError) -> Heard<[(AXUIElement, ScreenRect?)]> {
        let app = bounded(AXUIElementCreateApplication(pid))
        guard case .answered(let value) = try attribute(kAXWindowsAttribute, of: app) else { return .unanswered }
        var windows: [(AXUIElement, ScreenRect?)] = []
        for window in (value as? [CFTypeRef] ?? []).compactMap(element).map(bounded) {
            guard case .answered(let position) = try attribute(kAXPositionAttribute, of: window),
                  case .answered(let size) = try attribute(kAXSizeAttribute, of: window) else { continue }
            windows.append((window, frame(position, size)))
        }
        return .answered(windows)
    }

    private static func frame(_ position: CFTypeRef?, _ size: CFTypeRef?) -> ScreenRect? {
        unboxed(position, as: .cgPoint, CGPoint.zero).flatMap { origin in
            unboxed(size, as: .cgSize, CGSize.zero).map { ScreenRect(CGRect(origin: origin, size: $0)) }
        }
    }

    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// One element's attributes, each read once and each outcome decided by `Answer`.
    /// Its facts are unanswered when any of the reads they are made from is, and its
    /// children stand apart: an element that will not say where it is may still say what
    /// is under it.
    static func node(_ element: AXUIElement) throws(TreeError) -> Node<AXUIElement> {
        let role = try attribute(kAXRoleAttribute, of: element)
        let texts = try [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].map { name throws(TreeError) in
            try attribute(name, of: element).map { $0 as? String }
        }
        let position = try attribute(kAXPositionAttribute, of: element)
        let size = try attribute(kAXSizeAttribute, of: element)
        let frame: Heard<ScreenRect?> = switch (position, size) {
        case (.answered(let position), .answered(let size)): .answered(Self.frame(position, size))
        default: .unanswered
        }
        return Node(
            facts: Facts(
                role: Role(rawValue: role.answer.flatMap { $0 as? String } ?? kAXUnknownRole),
                texts: texts,
                frame: frame
            ),
            children: try attribute(kAXChildrenAttribute, of: element).map { value in
                (value as? [CFTypeRef] ?? []).compactMap(Self.element).map(bounded)
            }
        )
    }

    /// One read. Absence is an answer of nothing; the rest is `Answer`'s to decide.
    /// [LAW:single-enforcer]
    private static func attribute(_ name: String, of element: AXUIElement) throws(TreeError) -> Heard<CFTypeRef?> {
        var value: CFTypeRef?
        switch try Answer(AXUIElementCopyAttributeValue(element, name as CFString, &value)) {
        case .answered: return .answered(value)
        case .absent: return .answered(nil)
        case .unanswered: return .unanswered
        }
    }

    /// A geometry value out of its `AXValue` box, when the app answered with one of the
    /// type asked for. A CoreFoundation value admits no cast check, so its type id is the
    /// check - an app answering with something else is refused, not trapped on.
    /// [LAW:parse-dont-validate]
    private static func unboxed<T: BitwiseCopyable>(_ value: CFTypeRef?, as type: AXValueType, _ empty: T) -> T? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var unboxed = empty
        return AXValueGetValue(value as! AXValue, type, &unboxed) ? unboxed : nil
    }

    private static func element(_ value: CFTypeRef) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
    }
}
