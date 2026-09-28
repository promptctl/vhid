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
/// about spent the whole element bound before reaching it.
///
/// Everything here is the edge - the grant and the reads. Which windows are walked is
/// `plan`, what an element becomes is `Facts.candidate`, how the tree is walked is
/// `walk`, and what matches is `Reading.judging`. [LAW:effects-at-boundaries]
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

    public func look(_ query: Query) async throws -> Candidates {
        // [LAW:no-silent-failure] Asked first: without the grant, every read fails, and a
        // walk that counted them as unanswered would report a looked-at, empty screen.
        guard AXIsProcessTrusted() else { throw TreeError.noGrant }
        let region = try query.region.bounds()
        let windows = try Geometry.onScreen().windows
        // Started before the windows are matched, because matching is reads too.
        let clock = ContinuousClock()
        let start = clock.now
        let visible = seen(windows, in: region)
        let (roots, unwalked) = plan(visible, matched: try Self.match(visible.map(\.window)))
        let walked = try walk(
            from: roots,
            unwalked: unwalked,
            within: Self.bounds,
            elapsed: { clock.now - start },
            read: Self.node
        )
        return Candidates(
            found: walked.found.inReadingOrder,
            region: region,
            examined: walked.examined,
            excluded: walked.excluded,
            reach: walked.reach
        )
    }

    /// The accessibility window for each on-screen window, by the window server's id.
    ///
    /// The two share no public id, so a window is matched by its owner and its frame, which
    /// both answer in the same points. Frames repeat - measured, a terminal listed three
    /// accessibility windows at one full-screen frame, two of them tabs on no screen - so
    /// each accessibility window is claimed once, by the frontmost on-screen window it
    /// matches; an app lists its windows front to back, which is assumed and not proven for
    /// tabs sharing one frame. A sheet is its own window to the window server and a child
    /// of its window to the tree, so each window's sheets are listed beside it: a sheet is
    /// then a root of its own, walked before the window behind it, which reaches the same
    /// sheet again only to find it covered. A window left unmatched is `plan`'s to count.
    static func match(_ windows: [Window]) throws(TreeError) -> [UInt32: AXUIElement] {
        var listed: [Int32: [(element: AXUIElement, frame: ScreenRect)]] = [:]
        var matched: [UInt32: AXUIElement] = [:]
        for window in windows {
            if listed[window.pid] == nil { listed[window.pid] = try Self.windows(of: window.pid) }
            guard let claimed = listed[window.pid]!.firstIndex(where: { same($0.frame, window.frame) }) else { continue }
            matched[window.id] = listed[window.pid]!.remove(at: claimed).element
        }
        return matched
    }

    /// Frames agree to the point; the two sources round differently below that.
    private static func same(_ a: ScreenRect, _ b: ScreenRect) -> Bool {
        abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// An app's windows and their sheets that said where they are, minimized windows left
    /// out - they keep their frame and are on no screen. An app that will not list them, or
    /// a window that will not say where it is, matches nothing and is counted by `plan` as
    /// unwalked - never dropped. [LAW:no-silent-failure]
    private static func windows(of pid: Int32) throws(TreeError) -> [(element: AXUIElement, frame: ScreenRect)] {
        let app = bounded(AXUIElementCreateApplication(pid))
        guard case .answered(let value?) = try read([kAXWindowsAttribute], of: app, as: [.structure])[0] else { return [] }
        var windows: [(element: AXUIElement, frame: ScreenRect)] = []
        for window in elements(value) {
            let reads = try read([kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, kAXChildrenAttribute],
                                 of: window, as: [.structure, .structure, .structure, .structure])
            guard case .answered(let position) = reads[0], case .answered(let size) = reads[1],
                  reads[2].answer.flatMap({ $0 as? Bool }) != true,
                  let frame = frame(position, size) else { continue }
            windows.append((window, frame))
            for child in elements(reads[3].answer ?? nil) {
                let sheet = try read([kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute], of: child, as: [.structure, .structure, .structure])
                guard sheet[0].answer.flatMap({ $0 as? String }) == kAXSheetRole,
                      case .answered(let position) = sheet[1], case .answered(let size) = sheet[2],
                      let frame = Self.frame(position, size) else { continue }
                windows.append((child, frame))
            }
        }
        return windows
    }

    private static func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        (value as? [CFTypeRef] ?? []).compactMap(element).map(bounded)
    }

    private static let attributes = [
        kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ]
    private static let parts: [Part] = [.structure, .text, .text, .text, .structure, .structure, .structure]

    /// One element: every attribute in one round trip, each outcome decided by `Answer`.
    static func node(_ element: AXUIElement) throws(TreeError) -> Node<AXUIElement> {
        let reads = try read(attributes, of: element, as: parts)
        let frame: Heard<ScreenRect?> = switch (reads[4], reads[5]) {
        case (.answered(let position), .answered(let size)): .answered(Self.frame(position, size))
        default: .unanswered
        }
        return Node(
            facts: Facts(
                role: Role(rawValue: reads[0].answer.flatMap { $0 as? String } ?? kAXUnknownRole),
                texts: reads[1...3].map { $0.map { $0 as? String } },
                frame: frame,
                named: { if case .answered = reads[0] { true } else { false } }()
            ),
            children: reads[6].map(elements)
        )
    }

    /// Several attributes in one call. The call's own failure fails every part; otherwise
    /// each value is either what the app answered or an `AXValue` carrying that attribute's
    /// own error. Absence is an answer of nothing. [LAW:single-enforcer]
    private static func read(_ names: [String], of element: AXUIElement, as parts: [Part]) throws(TreeError) -> [Heard<CFTypeRef?>] {
        var values: CFArray?
        let call = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard try Answer(call, for: .structure) == .answered, let values = values as? [CFTypeRef], values.count == names.count else {
            return names.map { _ in .unanswered }
        }
        var heard: [Heard<CFTypeRef?>] = []
        for (value, part) in zip(values, parts) {
            switch try Answer(axError(value) ?? .success, for: part) {
            case .answered: heard.append(.answered(CFGetTypeID(value) == CFNullGetTypeID() ? nil : value))
            case .absent: heard.append(.answered(nil))
            case .unanswered: heard.append(.unanswered)
            }
        }
        return heard
    }

    /// The error an attribute came back as, when it came back as one.
    private static func axError(_ value: CFTypeRef) -> AXError? {
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else { return nil }
        var error = AXError.success
        return AXValueGetValue(value as! AXValue, .axError, &error) ? error : nil
    }

    static func frame(_ position: CFTypeRef?, _ size: CFTypeRef?) -> ScreenRect? {
        unboxed(position, as: .cgPoint, CGPoint.zero).flatMap { origin in
            unboxed(size, as: .cgSize, CGSize.zero).map { ScreenRect(CGRect(origin: origin, size: $0)) }
        }
    }

    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
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
