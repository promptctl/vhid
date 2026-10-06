import AppKit
import IOKit.hidsystem
// Prints NSEvent's double-click interval and delay until a held key repeats, in seconds.
// With a key and nanoseconds, e.g. `HIDClickTime 900000000` or `HIDInitialKeyRepeat 300000000`, first sets
// that IOHIDSystem parameter, which needs root. Run it once to set, then as each user to read.
let arguments = CommandLine.arguments.dropFirst()
if arguments.count == 2 {
    guard let nanoseconds = UInt64(arguments.last!) else {
        FileHandle.standardError.write("usage: human-hid-params [HIDClickTime|HIDInitialKeyRepeat nanoseconds]\n".data(using: .utf8)!); exit(64)
    }
    let handle = NXOpenEventStatus()
    var value = nanoseconds
    let result = IOHIDSetParameter(handle, arguments.first! as CFString, &value, IOByteCount(MemoryLayout<UInt64>.size))
    NXCloseEventStatus(handle)
    guard result == KERN_SUCCESS else {
        FileHandle.standardError.write("IOHIDSetParameter: \(result), run as root\n".data(using: .utf8)!); exit(77)
    }
} else if !arguments.isEmpty {
    FileHandle.standardError.write("usage: human-hid-params [HIDClickTime|HIDInitialKeyRepeat nanoseconds]\n".data(using: .utf8)!); exit(64)
}
print(NSEvent.doubleClickInterval, NSEvent.keyRepeatDelay)
