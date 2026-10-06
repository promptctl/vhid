import CoreGraphics
import Foundation

/// The `--read-screen-in <audit session>` in argv, or nil when this is the daemon.
func screenReaderArgument(_ arguments: [String]) -> au_asid_t? {
    guard let flag = arguments.firstIndex(of: screenReaderFlag), flag + 1 < arguments.endIndex else { return nil }
    return au_asid_t(arguments[flag + 1])
}

/// What the daemon asks a screen reader, one line each.
enum ScreenQuestion: String {
    /// Answered `x y`.
    case cursor
    /// Answered `x y width height` for each online display, separated by `;`.
    case displays
}

/// The answer to either question when the window server would not give one: said apart
/// from a garbled answer so the daemon's log names the window server.
let refusedAnswer = "refused"

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
        case .cursor: print(CGEvent(source: nil).map { "\($0.location.x) \($0.location.y)" } ?? refusedAnswer)
        case .displays: print(onlineDisplays())
        case nil: print("asked '\(line)', which is no question")
        }
    }
    exit(0)
}

/// The online displays' bounds, in the global space the cursor is read in, as `displays` is
/// answered; `refusedAnswer` when the window server would not list them.
///
/// **Online, not active.** A display that has gone to sleep is not active, and the cursor
/// still moves on it and its Dock still rises: on studious, its one display asleep, the
/// active list was empty and the online list held it at (0, 0, 1600, 900). The members of a
/// mirror set are all online with one frame, which only says that frame twice.
private func onlineDisplays() -> String {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return refusedAnswer }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return refusedAnswer }
    return ids.prefix(Int(count)).map(CGDisplayBounds).map { "\($0.minX) \($0.minY) \($0.width) \($0.height)" }.joined(separator: ";")
}
