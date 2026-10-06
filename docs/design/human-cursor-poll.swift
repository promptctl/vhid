import CoreGraphics
import Foundation
// Prints every change of the cursor's location, with microseconds since the epoch, for argv[1] seconds.
let end = Date().addingTimeInterval(Double(CommandLine.arguments[1])!)
var last = CGEvent(source: nil)!.location
while Date() < end {
    let now = CGEvent(source: nil)!.location
    if now != last { print(Int64(Date().timeIntervalSince1970 * 1_000_000), now.x, now.y); last = now }
    usleep(200)
}
