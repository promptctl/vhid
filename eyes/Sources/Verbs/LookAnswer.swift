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

        fileprivate init(_ asked: Asked) { self.asked = asked }
    }

    /// [LAW:types-are-the-program] A text's own qualifiers, near and wait among them, exist
    /// only beside the text they qualify.
    enum Asked: Sendable {
        /// The displays and the windows, then every run in a place.
        case overview(Where.Place, role: Role?, source: SourceKind, limit: Limit)
        /// The runs matching a text in a place, ordered near another, waited on.
        case find(Where.Place, Match, near: Match?, role: Role?, source: SourceKind, limit: Limit, wait: Wait?)
        /// What a click at this point would land on.
        case at(ScreenPoint)
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
            let places = Where.places(app: app, display: display, window: window, page: page, rect: rect)
            let narrowing = [given(["text": text != nil, "role": role != nil, "source": source != nil, "limit": limit != nil]), given(places)]
                .filter { !$0.isEmpty }.joined(separator: ", ")
            guard narrowing.isEmpty, qualifiers.isEmpty else {
                throw ValidationError("\(s("x")) and \(s("y")) ask what a click there lands on, which nothing else narrows:"
                    + " give them without \([narrowing, qualifiers].filter { !$0.isEmpty }.joined(separator: ", "))")
            }
            return Question(.at(try Hit.point(x, y)))
        case (nil, nil):
            break
        default:
            throw ValidationError("give \(s("x")) and \(s("y")) together: the point a click would land on")
        }
        let place = try Where.place(app: app, display: display, window: window, page: page, rect: rect, as: s)
        let kind = try source.map { try named(SourceKind.self, $0, as: s("source")) } ?? .merged
        let (wanted, rows) = (try Find.role(role, source: kind, as: s), try Where.limit(limit ?? Limit.default.count, as: s))
        guard let text else {
            guard qualifiers.isEmpty else { throw ValidationError("give \(s("text")), the text to find, for \(qualifiers) to qualify") }
            return Question(.overview(place, role: wanted, source: kind, limit: rows))
        }
        return Question(.find(
            place, try Find.match(text, exact: exact, edits: edits, as: s), near: try Find.near(near), role: wanted, source: kind,
            limit: rows, wait: try Find.wait(try until.map { try named(Until.self, $0, as: s("until")) }, timeout: timeout, as: s)))
    }

    /// One of a closed set of names, or the refusal naming the argument and the set.
    private static func named<T: CaseIterable & RawRepresentable<String>>(_: T.Type, _ value: String, as argument: String) throws -> T {
        guard let named = T(rawValue: value) else {
            throw ValidationError("\(argument) is \(value), and it takes one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return named
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
    /// takes, and the names `app` takes - and lead it still when the place cannot be read,
    /// since they are what the caller names another place by. A look for a text or at a
    /// point answers that alone, its scope line naming the app and display it read, so a
    /// caller looking again and again is not handed the whole desk each time.
    public static func answer(_ question: Question, on screen: Screen) async throws -> String {
        switch question.asked {
        case .at(let point):
            return try await served { try await Hit.answer(at: point, landing: screen.landing) }
        case .overview(let place, let role, let source, let limit):
            let picture = try await overview(screen)
            do {
                return (picture + [try await text(nil, near: nil, role: role, limit: limit, in: place, by: source, waiting: nil, on: screen)])
                    .joined(separator: "\n\n")
            } catch let refused as Refused {
                throw Refused(description: (picture + [refused.description]).joined(separator: "\n\n"))
            }
        case .find(let place, let match, let near, let role, let source, let limit, let wait):
            return try await text(match, near: near, role: role, limit: limit, in: place, by: source, waiting: wait, on: screen)
        }
    }

    /// The runs `match` asks for, or every run, read in `place` once it is found.
    private static func text(_ match: Match?, near: Match?, role: Role?, limit: Limit, in place: Where.Place, by source: SourceKind,
                             waiting wait: Wait?, on screen: Screen) async throws -> String {
        let region = try await served { try await place.region(pages: screen.pages, front: screen.front) }
        let query = Query(match: match, region: region, limit: limit, near: near, role: role)
        return try await served { try await Report.text(query, source: source, wait: wait, reading: screen.read) }
    }

    /// The displays and the windows. The frontmost app is read before the listing, so an
    /// activation lands before the listing that reflects it.
    private static func overview(_ screen: Screen) async throws -> [String] {
        let frontmost = await screen.frontmost()
        return [Displays.report(await screen.displays()), Windows.report(try await screen.listing(), owner: nil, frontmost: frontmost)]
    }

    /// A failure as a look says it: an app with nothing to read, a missing grant, a merge
    /// neither of whose readers could look, each in the words a caller acts on.
    /// [LAW:no-silent-failure]
    private static func served<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let both as BothBlind {
            throw Refused(description: "Neither reader could look. \(both.first) \(both.second)")
        } catch let error as ReaderError where error.missingGrant {
            throw Refused(description: "\(error)")
        } catch let unread as AppUnread {
            throw Refused(description: "\(unread)")
        }
    }

    /// A look that could not read what it was asked to, in the words a caller acts on.
    struct Refused: Error, CustomStringConvertible {
        let description: String
    }
}
