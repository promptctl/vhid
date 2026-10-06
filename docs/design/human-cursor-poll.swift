import CoreGraphics
import Foundation
// Prints every change of the cursor's location, with microseconds since the epoch, for argv[1] seconds.
// Run it as the user logged in at the screen; a process outside that session reads a cursor that never moves.
guard CommandLine.arguments.count == 2, let seconds = Double(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: human-cursor-poll <seconds>\n".data(using: .utf8)!); exit(64)
}
func location() -> CGPoint {
    guard let event = CGEvent(source: nil) else {
        FileHandle.standardError.write("no window server connection: run in the logged-in session\n".data(using: .utf8)!); exit(69)
    }
    return event.location
}
let end = Date().addingTimeInterval(seconds)
var last = location()
while Date() < end {
    let now = location()
    if now != last { print(Int64(Date().timeIntervalSince1970 * 1_000_000), now.x, now.y); last = now }
    usleep(200)
}
