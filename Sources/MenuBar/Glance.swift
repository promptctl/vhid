import Doctor
import Foundation
import Helper
import Installations

/// What vhid's menu bar item shows, as a value: the icon, and the rows under it.
///
/// [LAW:effects-at-boundaries] Nothing here reads anything. The readings arrive as
/// values - doctor's `Readiness` and the daemon's last failure - so every menu a Mac can
/// produce is one a test constructs, and the AppKit side only draws it.
///
/// [LAW:one-source-of-truth] Ready means what `vhid doctor` means by it: the icon is
/// `Readiness.ready`, and the rows are doctor's rows in doctor's words. Who holds the
/// devices is doctor's Devices row, not a reading of this item's own.
public struct Glance: Sendable, Hashable {
    /// Whether nothing is left for anyone to do, as doctor judges it.
    public let ready: Bool
    /// What tells this copy from vhid's installed one on the menu bar itself, and nil for
    /// the installed one, which is the copy a person expects to see there.
    public let badge: String?
    public let rows: [Row]

    /// One line of the menu. Clicking it copies `text`, the whole of it, which the title
    /// may shorten.
    public struct Row: Sendable, Hashable {
        public enum Mark: Sendable, Hashable {
            /// Nothing is left to do about it.
            case met
            /// Something is left to do, and the text says what.
            case unmet
            /// Something went wrong. Marked apart from `unmet`, because a step is waiting
            /// on a person and an error already happened.
            case error
            /// Neither: which copy this is and when it was read.
            case about
        }

        public let mark: Mark
        public let text: String

        /// The text's first line, cut to what a menu can show. Derived rather than written
        /// beside the text, so the two cannot come to name different things.
        /// [LAW:one-source-of-truth]
        public var title: String {
            let line = text.prefix { !$0.isNewline }
            return line.count <= Self.widest ? String(line) : line.prefix(Self.widest - 1) + "…"
        }

        static let widest = 100
    }

    /// The menu for `installation` from what was read of it at `readAt`.
    ///
    /// The last failure is a `Result` because asking for it is a call that can fail - a
    /// daemon that is not running answers nothing, and one older than this item does not
    /// know the question. That failure is itself an error row: a menu that dropped the row
    /// would read as a daemon with nothing to report. [LAW:no-silent-failure]
    public init(installation: Installation, readiness: Readiness, lastFailure: Result<DaemonFailure?, any Error>, readAt: Date) {
        ready = readiness.ready
        badge = installation == .release ? nil : installation.service.split(separator: ".").last.map(String.init)
        rows = [Self.about(installation, readAt)]
            + readiness.requirements.map { Row(mark: $0.met ? .met : .unmet, text: $0.description) }
            + [Self.failure(lastFailure)]
    }

    private static func about(_ installation: Installation, _ readAt: Date) -> Row {
        Row(mark: .about, text: "\(installation.service), read at \(clock(readAt))")
    }

    /// [LAW:dataflow-not-control-flow] Every way the question ends is a row: a failure,
    /// none, or why it could not be asked.
    private static func failure(_ lastFailure: Result<DaemonFailure?, any Error>) -> Row {
        switch lastFailure {
        case .success(let failure?): Row(mark: .error, text: "Last failure, at \(clock(failure.at)): \(failure.text)")
        case .success(nil): Row(mark: .met, text: "No failure since vhidd started")
        case .failure(let error): Row(mark: .error, text: "The last failure could not be read: \(error)")
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
