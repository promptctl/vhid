import CoreGraphics
import DisplayReading
import Foundation
import ScreenSpace

/// The `--read-screen-in <audit session>` in argv, or nil when this is the daemon.
func screenReaderArgument(_ arguments: [String]) -> au_asid_t? {
    guard let flag = arguments.firstIndex(of: screenReaderFlag), flag + 1 < arguments.endIndex else { return nil }
    return au_asid_t(arguments[flag + 1])
}

/// What the daemon asks a screen reader, one line each.
enum ScreenQuestion: String {
    /// Answered `x y`.
    case cursor
    /// Answered with each online display's `OnlineDisplay.record`, as `spelled` writes it.
    case displays
}

/// What begins the answer to either question when the window server would not give one, the
/// reason after it: said apart from a garbled answer so the daemon names the window server
/// and why. [LAW:no-silent-failure]
let refusedAnswer = "refused: "

/// The child `FrontScreen` starts: joins `session` and says so, and which build it is,
/// then answers each question on stdin on a line of stdout, until stdin closes.
///
/// The join comes before the first read, because the first read is what ties a process to
/// a session (see `FrontScreen`). A join that fails says so instead, with the reason, on stdout,
/// where the daemon reads it and logs it; the daemon's stderr goes nowhere.
/// [LAW:no-silent-failure]
func readScreen(in session: au_asid_t) -> Never {
    var port: mach_port_t = 0
    setvbuf(stdout, nil, _IOLBF, 0)
    guard audit_session_port(session, &port) == 0, audit_session_join(port) == session else {
        print("could not join audit session \(session): errno \(errno)")
        exit(1)
    }
    do {
        print("\(joinedAnswer) \(try Build.ofThisProcess())")
    } catch {
        print("could not say which build it is: \(error)")
        exit(1)
    }
    while let line = readLine() {
        switch ScreenQuestion(rawValue: line) {
        case .cursor: print(CGEvent(source: nil).map { "\($0.location.x) \($0.location.y)" } ?? refusedAnswer + "it gave no event to read the cursor from")
        case .displays:
            do { print(try spelled(OnlineDisplay.read())) } catch { print(refusedAnswer + "\(error)") }
        case nil: print("asked '\(line)', which is no question")
        }
    }
    exit(0)
}

/// The online displays as `displays` is answered: each display's record, its numbers apart by
/// spaces, the displays by `;`. The one layout read's readings, so the daemon reads the
/// displays as both halves do. [LAW:one-source-of-truth]
private func spelled(_ displays: [OnlineDisplay]) -> String {
    displays.map { $0.record.map { "\($0)" }.joined(separator: " ") }.joined(separator: ";")
}
