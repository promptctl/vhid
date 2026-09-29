import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import Input
import KeyboardLayouts
import Keystrokes
import Pointing
import RecordingTie

// The tap app `vhid record` launches: `vhid-record <socket> <command pid>`.
//
// `docs/design/replay.md` is the design. What this file owns is the effect - the session
// tap, the I/O Registry, the socket and the clock - and every decision about what a
// recording says is `Recorder`'s, on the values this hands it. [LAW:effects-at-boundaries]

let arguments = CommandLine.arguments
guard arguments.count == 3, let commandPID = pid_t(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: vhid-record <socket> <command pid>; vhid record launches this\n".utf8))
    exit(64)
}

// Connected before anything else, and the app exits if it cannot be: a tap nobody is
// listening to is a tap nothing will ever stop.
let command: TieEnd
do {
    command = try TieEnd.connect(to: arguments[1])
} catch {
    FileHandle.standardError.write(Data("vhid-record: \(error)\n".utf8))
    exit(1)
}
// The command gone, however it went, ends the app: no tap outlives it.
let watch = CommandWatch(pid: commandPID, queue: .main) { exit(1) }

func refuse(_ reason: String) -> Never {
    try? command.send(FromApp.refused(reason))
    exit(1)
}

// [LAW:no-silent-failure] Refused by name, and asked for, which is what lists the bundle
// under Input Monitoring for the person to switch on.
guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    // The path too: macOS does not always list an app that asked, and a person adding it
    // by hand has to be able to find it.
    refuse("Input Monitoring is not granted to vhid-record (\(Bundle.main.bundleIdentifier ?? arguments[0])). In System Settings > Privacy & Security > Input Monitoring, switch it on - or, if it is not listed, click + and add \(Bundle.main.bundlePath) - then run vhid record again")
}

let stopKeys: Set<Usage>
do {
    stopKeys = try Recorder.stopKeys(on: KeyboardLayout.current())
} catch {
    refuse("the stop chord cannot be read off the keyboard layout: \(error)")
}

/// The registry IDs vhid's events carry in tap field 87: every service under a pqrs
/// virtual keyboard or pointing device. Measured: vhid's motion carries the ID of the
/// `AppleUserHIDEventService` two levels under the device, so the whole subtree is taken.
func vhidSenders() throws -> Set<UInt64> {
    var devices: io_iterator_t = 0
    let found = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleUserHIDDevice"), &devices)
    guard found == KERN_SUCCESS else { throw TieFailure("the I/O Registry could not be searched for vhid's devices: kern_return \(found)") }
    defer { IOObjectRelease(devices) }
    var senders: Set<UInt64> = []
    while case let device = IOIteratorNext(devices), device != 0 {
        defer { IOObjectRelease(device) }
        let userClass = IORegistryEntryCreateCFProperty(device, "IOUserClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard userClass?.hasPrefix("org_pqrs_Karabiner_DriverKit_VirtualHID") == true else { continue }
        senders.insert(try registryID(of: device))
        var below: io_iterator_t = 0
        let walked = IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &below)
        guard walked == KERN_SUCCESS else { throw TieFailure("the services under a pqrs device could not be read: kern_return \(walked)") }
        defer { IOObjectRelease(below) }
        while case let service = IOIteratorNext(below), service != 0 {
            defer { IOObjectRelease(service) }
            senders.insert(try registryID(of: service))
        }
    }
    return senders
}

func registryID(of entry: io_registry_entry_t) throws -> UInt64 {
    var id: UInt64 = 0
    let read = IORegistryEntryGetRegistryEntryID(entry, &id)
    guard read == KERN_SUCCESS else { throw TieFailure("a pqrs service's registry ID could not be read: kern_return \(read)") }
    return id
}

let initialSenders: Set<UInt64>
do {
    initialSenders = try vhidSenders()
} catch {
    // Field 87 is not a published field, so without the IDs there is no telling vhid's
    // events from the person's, and nothing is recorded rather than everything.
    refuse("vhid's own devices could not be told apart: \(error)")
}

/// Whether a point is on the edge of a display, where motion can be stopped short.
@Sendable func atEdge(_ point: ScreenPoint) -> Bool {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    let x = CGFloat(point.x), y = CGFloat(point.y)
    return displays.map(CGDisplayBounds).contains { (bounds: CGRect) -> Bool in
        let inside = bounds.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: x, y: y))
        let onEdge = x <= bounds.minX || x >= bounds.maxX - 1 || y <= bounds.minY || y >= bounds.maxY - 1
        return inside && onEdge
    }
}

// Read here, not through vhidd: a recording taps this session's events, so it only
// records in the session it can read the cursor in.
guard let startPoint = CGEvent(source: nil)?.location else { refuse("the cursor could not be read") }
guard let start = ScreenPoint(x: startPoint.x, y: startPoint.y) else { refuse("the cursor's position \(startPoint) is not a point") }
let clock = ContinuousClock()
/// The tap's own clock at the start: nanoseconds since boot, which every event's
/// timestamp is on. An event's time is when it happened, not when the tap handed it over.
let startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
/// A script's times stop at an hour, which is as long as a recording runs.
let hour = Duration.milliseconds(Int64(Play.longest))
let hourNote = "the recording reached an hour, the longest a script plays, and stopped"
/// Now, on the events' clock.
func sinceStart() -> Duration { .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) - Int64(startedAt)) }

/// The recording, and whether it is still taking events. Touched on the main queue only,
/// where the tap and every message are delivered.
@MainActor final class Session {
    var recorder: Recorder
    var taking = true
    /// Whether a stop or an end has begun; the first one is the ending, and later ones
    /// change nothing.
    private var finishing = false

    init(recorder: Recorder) { self.recorder = recorder }

    /// Sends the recording and exits: a stop waits up to half a second, or until nothing
    /// is held, for the stop chord's own releases, and takes out its keys.
    func finish(_ ending: ToApp, notes: [String] = []) {
        guard !finishing else { return }
        finishing = true
        // Never past an hour, which is as far as a script's times go.
        let stoppedAt = min(sinceStart(), hour)
        let deadline = clock.now + .milliseconds(500)
        func send() {
            taking = false
            var said = notes
            if recorder.unmapped > 0 { said.append("\(recorder.unmapped) key presses with no HID usage, fn among them, are not in the recording") }
            if recorder.vhidAtEdge > 0 { said.append("vhid's motion reached a screen edge \(recorder.vhidAtEdge) times while recording, so the pointer points after it may be off") }
            do {
                for note in said { try command.send(FromApp.note(note)) }
                try command.send(FromApp.script(recorder.script(stoppedAt: stoppedAt, stopKeys: ending == .stop ? stopKeys : [])))
                exit(0)
            } catch {
                exit(1)
            }
        }
        func wait() {
            guard recorder.holdsKeys, clock.now < deadline else { return send() }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10), execute: wait)
        }
        ending == .stop ? wait() : send()
    }
}

let session = MainActor.assumeIsolated {
    Session(recorder: Recorder(start: start, flags: CGEventSource.flagsState(.combinedSessionState).rawValue, vhid: initialSenders, atEdge: atEdge))
}

/// A tap event as the recorder reads it, or nil for a kind it does not record.
func tapEvent(_ type: CGEventType, _ event: CGEvent) -> TapEvent? {
    let location = event.location
    guard let place = ScreenPoint(x: location.x, y: location.y) else { return nil }
    let button = { Button(rawValue: UInt8(event.getIntegerValueField(.mouseEventButtonNumber) + 1)) }
    let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let kind: TapEvent.Kind?
    switch type {
    case .keyDown: kind = .keyDown(keyCode: code, autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    case .keyUp: kind = .keyUp(keyCode: code)
    case .flagsChanged: kind = .flagsChanged(keyCode: code, flags: event.flags.rawValue)
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .motion
    case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = button().map { .buttonDown($0) }
    case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = button().map { .buttonUp($0) }
    default: kind = nil
    }
    // Field 87: the registry ID of the service that sent it; not a published CGEventField.
    let at = Duration.nanoseconds(Int64(event.timestamp) - Int64(startedAt))
    return kind.map { TapEvent(at: max(at, .zero), sender: UInt64(bitPattern: event.getIntegerValueField(CGEventField(rawValue: 87)!)), location: place, kind: $0) }
}

let kinds: [CGEventType] = [
    .keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
]
let mask = kinds.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, _ in
    MainActor.assumeIsolated {
        // A tap macOS turned off has missed events, so what it recorded is ended there
        // rather than carried on with a gap in it, and said so.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            session.finish(.end, notes: ["macOS turned the tap off (\(type == .tapDisabledByTimeout ? "too slow" : "by user input")), so the recording ends there"])
        } else if session.taking, let taken = tapEvent(type, event) {
            if taken.at > hour { session.finish(.end, notes: [hourNote]) } else { session.recorder.take(taken) }
        }
    }
    return Unmanaged.passUnretained(event)
}, userInfo: nil) else {
    refuse("macOS would not make a listen-only session tap")
}
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)

// vhidd or the driver restarting re-creates the devices under new IDs, so the IDs are read
// again whenever an event service appears. [LAW:one-source-of-truth] The registry is the
// one source; the recorder's set is its latest reading.
guard let notifications = IONotificationPortCreate(kIOMainPortDefault) else {
    refuse("vhid's devices could not be watched for coming back under new IDs")
}
IONotificationPortSetDispatchQueue(notifications, .main)
var appeared: io_iterator_t = 0
let reread: IOServiceMatchingCallback = { _, iterator in
    while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    MainActor.assumeIsolated {
        do {
            session.recorder.vhid = try vhidSenders()
        } catch {
            session.finish(.end, notes: ["vhid's devices came back and could not be told apart again (\(error)), so the recording ends there"])
        }
    }
}
let watching = IOServiceAddMatchingNotification(notifications, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"), reread, nil, &appeared)
guard watching == KERN_SUCCESS else {
    refuse("vhid's devices could not be watched for coming back under new IDs: kern_return \(watching)")
}
reread(nil, appeared)

// An hour with no event ends the recording too.
DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(Play.longest))) {
    MainActor.assumeIsolated { session.finish(.end, notes: [hourNote]) }
}

try? command.send(FromApp.recording)
Thread.detachNewThread {
    // The command's messages, and its end: a socket closed without a word is the command
    // gone, and so is the app.
    while let message = try? command.receive(ToApp.self) {
        DispatchQueue.main.async { MainActor.assumeIsolated { session.finish(message) } }
    }
    DispatchQueue.main.async { exit(1) }
}
withExtendedLifetime(watch) { CFRunLoopRun() }
