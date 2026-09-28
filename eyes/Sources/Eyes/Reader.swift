/// Something that can say what text is on screen and where.
///
/// Two readers answer this: one walks the accessibility tree, one recognises pixels. They
/// are two behaviors and so two types, and they conform to one protocol so a caller holds
/// a reader without knowing or caring which. [LAW:composability] That is also what makes
/// a merged reader possible - one that asks both and reconciles the answers is a third
/// conformance, not a branch at every call site. [LAW:dataflow-not-control-flow]
///
/// Main-actor because reading the screen is a question about the user's session.
@MainActor
public protocol Reader: Sendable {
    /// What this reader is, for a finding to carry and a caller to read back.
    var source: SourceKind { get }

    /// Everything the reader saw in the query's region, before any of it is judged
    /// against the query, or a throw when it could not look at all. `read` judges it.
    ///
    /// Unjudged so a merged reader reconciles what two readers saw rather than what
    /// survived each one's match and limit, and judges the union once. [LAW:single-enforcer]
    ///
    /// A region with nothing in it is an answer and comes back as one, carrying its
    /// scope. Throwing is for a reader that could not see - no grant, no such display, a
    /// capture that wrote nothing - because those are facts about the tool and not about
    /// the screen, and a caller told "nothing matched" would take them for an absence.
    /// [LAW:no-silent-failure]
    func look(_ query: Query) async throws -> Candidates
}

public extension Reader {
    /// Answers the query: what the reader saw, judged by the one rule every reader shares.
    func read(_ query: Query) async throws -> Reading {
        Reading.judging(try await look(query), query: query)
    }
}

/// Which kind of reader, without the per-finding payload `Source` carries.
public enum SourceKind: String, Sendable, Hashable {
    case tree
    case pixels
    /// Both, reconciled.
    case merged
}

public extension Source {
    var kind: SourceKind {
        switch self {
        case .tree: .tree
        case .pixels: .pixels
        case .merged: .merged
        }
    }
}
