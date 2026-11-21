import ArgumentParser
import Seeing
import Telemetry

/// What a look was asked, read once from the arguments a verb or a tool was given, each
/// naming them the way its caller spells them. [LAW:parse-dont-validate] What is answered
/// is decided here, so no answer branches on which arguments happened to be given.
public struct Asked: Sendable {
    let question: Question

    enum Question: Sendable {
        /// The displays and the windows, and the text in a place.
        case overview(Sight)
        /// Where text is in a place, waiting for it to come or go when asked to.
        case find(Sight, Match, near: Match?, wait: Wait?)
        /// What a click at a point would land on.
        case at(ScreenPoint)
    }

    /// A place's text, as a look reads it: where, how many rows, by which reader, of which role.
    struct Sight: Sendable {
        let place: Where.Place
        let limit: Limit
        let source: SourceKind
        let role: Role?
    }

    /// The question these arguments ask, or the refusal naming what does not fit.
    /// [LAW:single-enforcer] The one rule for `vhid look` and the `look` tool.
    public static func parsed(
        text: String?, exact: Bool, edits: Int?, near: String?, until: Until?, timeout: Double?,
        display: UInt32?, window: UInt32?, page: UInt32?, rect: String?, app: String?,
        limit: Int?, source: SourceKind?, role: String?, x: Double?, y: Double?, as s: Spelling
    ) throws -> Asked {
        let finding = [("exact", exact), ("edits", edits != nil), ("near", near != nil), ("until", until != nil), ("timeout", timeout != nil)]
        let reading = [("display", display != nil), ("window", window != nil), ("page", page != nil), ("rect", rect != nil), ("app", app != nil),
                       ("limit", limit != nil), ("source", source != nil), ("role", role != nil)]
        let given = { (arguments: [(String, Bool)]) in arguments.filter(\.1).map { s($0.0) } }
        if x != nil || y != nil {
            guard let x, let y else { throw ValidationError("give \(s("x")) and \(s("y")) together: the point a click would land on") }
            let also = given([("text", text != nil)] + finding + reading)
            guard also.isEmpty else {
                throw ValidationError("\(s("x")) and \(s("y")) ask what a click there would land on, which takes nothing else, and \(also.joined(separator: ", ")) was given too")
            }
            return Asked(question: .at(try Hit.point(x, y)))
        }
        let source = source ?? .merged
        let sight = Sight(place: try Where.place(display: display, window: window, page: page, rect: rect, app: app, as: s),
                          limit: try Where.limit(limit ?? Limit.default.count, as: s), source: source,
                          role: try Find.role(role, source: source, as: s))
        guard let text else {
            let stray = given(finding)
            guard stray.isEmpty else { throw ValidationError("\(stray.joined(separator: ", ")) needs \(s("text")), the text to find") }
            return Asked(question: .overview(sight))
        }
        return Asked(question: .find(sight, try Find.match(text, exact: exact, edits: edits, as: s), near: try Find.near(near),
                                     wait: try Find.wait(until, timeout: timeout, as: s)))
    }

    /// The answer, read from `screen` now.
    @MainActor
    public func answer(on screen: Screen = .live) async throws -> String {
        switch question {
        case .at(let point):
            return try await Hit.answer(at: point, landing: screen.land)
        case .find(let sight, let match, let near, let wait):
            return try await sight.text(match, near: near, wait: wait, on: screen, desk: screen.desk)
        case .overview(let sight):
            // [LAW:nothing-unseen] One unit for the overview, whose result says whether the
            // place was read; the displays and windows are answered either way.
            return try await Telemetry.unit("overview", result: { $0.result }) {
                let desk = try await screen.desk()
                let place: Result<String, any Error>
                do {
                    place = .success(try await sight.text(nil, near: nil, wait: nil, on: screen, desk: { desk }))
                } catch where !error.isCancellation {
                    place = .failure(error)
                }
                return (text: Self.overview(desk, place), result: (try? place.get()) == nil ? "place_unread" : "read")
            }.text
        }
    }

    /// The displays, the windows front to back, then the place's text or why it was not
    /// read: every part from the one desk, rendered once whatever the place came to.
    /// [LAW:one-source-of-truth] Pure, so a test reads what an agent is told.
    static func overview(_ desk: Desk, _ place: Result<String, any Error>) -> String {
        let text = switch place {
        case .success(let text): text
        case .failure(let error): "No text was read: \(error)."
        }
        return [Displays.report(desk.displays), Windows.report(desk.listing, owner: nil, frontmost: desk.frontmost), text]
            .joined(separator: "\n\n")
    }
}

extension Asked.Sight {
    /// This place's text, matched against `match` when there is one, with the place found
    /// on `desk`.
    @MainActor
    func text(_ match: Match?, near: Match?, wait: Wait?, on screen: Screen, desk: @escaping Where.Place.Desks) async throws -> String {
        let region = try await place.region(pages: screen.pages, desk: desk)
        return try await Report.text(Query(match: match, region: region, limit: limit, near: near, role: role),
                                     source: source, wait: wait, reading: screen.read)
    }
}

/// The screen, as a look reads it: the desk, a window's pages, the readers, and the hit
/// test - in the process, or fakes in a test. [LAW:effects-at-boundaries]
public struct Screen: Sendable {
    let desk: Where.Place.Desks
    let pages: Where.Place.Pages
    let read: @Sendable (SourceKind, Query) async throws -> Judged
    let land: Hit.Landings

    init(desk: @escaping Where.Place.Desks = Where.Place.live, pages: @escaping Where.Place.Pages = Where.Place.tree,
         read: @escaping @Sendable (SourceKind, Query) async throws -> Judged = Self.reader,
         land: @escaping Hit.Landings = { try await Hit.land(at: $0) }) {
        self.desk = desk
        self.pages = pages
        self.read = read
        self.land = land
    }

    /// The screen with its desk and readers written by a test, and the rest as it is.
    public init(desk: @escaping @Sendable @MainActor () async throws -> Desk,
                read: @escaping @Sendable (SourceKind, Query) async throws -> Judged) {
        self.init(desk: desk, pages: Where.Place.tree, read: read)
    }

    public static let live = Screen()

    /// The reader of each kind, in the process.
    static let reader: @Sendable (SourceKind, Query) async throws -> Judged = { @MainActor in try await $0.reader.judged($1) }
}
