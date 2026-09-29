import CoreGraphics
import Foundation

/// The `--read-cursor-in <audit session>` in argv, or nil when this is the daemon.
func cursorReaderArgument(_ arguments: [String]) -> au_asid_t? {
    guard let flag = arguments.firstIndex(of: cursorReaderFlag), flag + 1 < arguments.endIndex else { return nil }
    return au_asid_t(arguments[flag + 1])
}

/// The child `FrontCursor` starts: joins `session` and says so, then answers each line on
/// stdin with the cursor as `x y` on stdout, until stdin closes.
///
/// The join comes before the first read, because the first read is what ties a process to
/// a session (see `FrontCursor`). A join that fails says so instead, with the reason, on stdout,
/// where the daemon reads it and logs it; the daemon's stderr goes nowhere.
/// [LAW:no-silent-failure]
func readCursor(in session: au_asid_t) -> Never {
    var port: mach_port_t = 0
    setvbuf(stdout, nil, _IOLBF, 0)
    guard audit_session_port(session, &port) == 0, audit_session_join(port) == session else {
        print("could not join audit session \(session): errno \(errno)")
        exit(1)
    }
    print(joinedAnswer)
    while readLine() != nil {
        print(CGEvent(source: nil).map { "\($0.location.x) \($0.location.y)" } ?? "unreadable")
    }
    exit(0)
}
