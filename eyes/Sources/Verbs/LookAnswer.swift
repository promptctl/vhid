import ArgumentParser
import Grants
import Pixels
import Seeing
import Telemetry
import Tree

/// The screen as one question an MCP client asks before it acts: which displays and windows
/// there are, then the text in a place, or what a click at a point would land on.
///
/// The rules are the verbs' own - `Where.place`, `Find`'s match, near, role and wait, `Hit`'s
/// point - so a look and the command line refuse and answer alike. [LAW:single-enforcer]
public enum Look {
    /// What a look asks, made only by `question`, so a value of it is arguments already
    /// held to every rule. [LAW:parse-dont-validate]
    public struct Question: Sendable {
        let asked: Asked
    }

    enum Asked: Sendable {
        /// What a click at this point would land on.
        case at(ScreenPoint)
        /// The text in a place: every run, or those matching, ordered near another, waited on.
        case text(Where.Place, Match?, near: Match?, role: Role?, source: SourceKind, limit: Limit, wait: Wait?)
    }

    /// The arguments of a look as a question, or the refusal naming the argument.
    ///
    /// A point asks something no other argument narrows, so it stands alone. The text's
    /// own qualifiers - exact, edits, near, until - qualify a text, so they need one.
    public static func question(
        app: String?, text: String?, exact: Bool, edits: Int?, near: String?, role: String?, source: String?, limit: Int?,
        display: UInt32?, window: UInt32?, page: UInt32?, rect: String?, x: Double?, y: Double?, until: String?, timeout: Double?,
        as s: Spelling
    ) throws -> Question {
        /// The names of those given, as the caller spells them.
        func given(_ arguments: KeyValuePairs<String, Bool>) -> String {
            arguments.filter(\.value).map { s($0.key) }.joined(separator: ", ")
        }
        let qualifiers = given(["exact": exact, "edits": edits != nil, "near": near != nil, "until": until != nil, "timeout": timeout != nil])
        switch (x, y) {
        case let (x?, y?):
            let narrowing = given(["app": app != nil, "text": text != nil, "role": role != nil, "source": source != nil, "limit": limit != nil,
                                   "display": display != nil, "window": window != nil, "page": page != nil, "rect": rect != nil])
            guard narrowing.isEmpty, qualifiers.isEmpty else {
                throw ValidationError("\(s("x")) and \(s("y")) ask what a click there lands on, which nothing else narrows:"
                    + " give them without \([narrowing, qualifiers].filter { !$0.isEmpty }.joined(separator: ", "))")
            }
            return Question(asked: .at(try Hit.point(x, y)))
        case (nil, nil):
            break
        default:
            throw ValidationError("give \(s("x")) and \(s("y")) together: the point a click would land on")
        }
        guard text != nil || qualifiers.isEmpty else {
            throw ValidationError("give \(s("text")), the text to find, for \(qualifiers) to qualify")
        }
        let kind = try source.map { named in
            guard let kind = SourceKind(rawValue: named) else {
                throw ValidationError("\(s("source")) is \(named), and it takes one of \(SourceKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return kind
        } ?? .merged
        let wanted = try until.map { named in
            guard let until = Until(rawValue: named) else {
                throw ValidationError("\(s("until")) is \(named), and it takes one of \(Until.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return until
        }
        return Question(asked: .text(
            try Where.place(app: app, display: display, window: window, page: page, rect: rect, as: s),
            try text.map { try Find.match($0, exact: exact, edits: edits, as: s) },
            near: try Find.near(near), role: try Find.role(role, source: kind, as: s), source: kind,
            limit: try Where.limit(limit ?? Limit.default.count, as: s), wait: try Find.wait(wanted, timeout: timeout, as: s)))
    }

    /// What a look reads the screen through: the window server, AppKit and the readers in
    /// the process, fakes a test wrote. [LAW:effects-at-boundaries]
    public struct Screen: Sendable {
        let listing: @Sendable () async throws -> WindowListing
        let frontmost: @Sendable () async -> Front.App?
        let displays: @Sendable () async -> [Display]
        let read: @Sendable (SourceKind, Query) async throws -> Judged
        let pages: Where.Place.Pages
        let front: Where.Place.Fronts
        let landing: Hit.Landings

        public static let live = Screen(
            listing: { try await Geometry.onScreen() }, frontmost: { await Front.App.now() }, displays: { Geometry.displays() },
            read: { source, query in try await source.reader.judged(query) }, pages: Where.Place.tree, front: Where.Place.live,
            landing: { try await Hit.land(at: $0) })
    }

    /// What the question asked. A look for no text in particular is the overview, so the
    /// displays and the windows, front to back, lead it: the ids every place argument
    /// takes, and the names `app` takes. A look for a text or at a point answers that alone,
    /// its scope line naming the app and display it read, so a caller looking again and
    /// again is not handed the whole desk each time.
    public static func answer(_ question: Question, on screen: Screen) async throws -> String {
        switch question.asked {
        case .at(let point):
            return try await served { try await Hit.answer(at: point, landing: screen.landing) }
        case .text(let place, let match, let near, let role, let source, let limit, let wait):
            let picture = match != nil ? [] : try await overview(screen)
            let region = try await served { try await place.region(pages: screen.pages, front: screen.front) }
            let query = Query(match: match, region: region, limit: limit, near: near, role: role)
            let seen = try await served {
                try await Report.text(query, source: source, wait: wait, grantNote: grantNote, reading: screen.read)
            }
            return (picture + [seen]).joined(separator: "\n\n")
        }
    }

    /// The displays and the windows. The frontmost app is read before the listing, so an
    /// activation lands before the listing that reflects it.
    private static func overview(_ screen: Screen) async throws -> [String] {
        let frontmost = await screen.frontmost()
        return [Displays.report(await screen.displays()), Windows.report(try await screen.listing(), owner: nil, frontmost: frontmost)]
    }

    /// Where a missing grant is held, for a server: the app running it, not vhid or eyes.
    static let grantNote = " Under an MCP server the grant is the app's that runs the server."

    /// A failure as a server says it: a missing grant names the app that must hold it, and a
    /// merge neither of whose readers could look says so for each. [LAW:no-silent-failure]
    private static func served<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let both as BothBlind {
            throw Refused(description: "Neither reader could look. \(said(both.first)) \(said(both.second))")
        } catch let error as ReaderError where error.missingGrant {
            throw Refused(description: said(error))
        }
    }

    private static func said(_ error: any Error) -> String {
        "\(error)\((error as? ReaderError)?.missingGrant == true ? grantNote : "")"
    }

    /// A look that could not read what it was asked to, in the words a caller acts on.
    struct Refused: Error, CustomStringConvertible {
        let description: String
    }
}
