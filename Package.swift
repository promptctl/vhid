// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "vhid",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Keystrokes", targets: ["Keystrokes"]),
        .library(name: "Pointing", targets: ["Pointing"]),
        .library(name: "Signals", targets: ["Signals"]),
        .library(name: "DriverExtension", targets: ["DriverExtension"]),
        .library(name: "KeyboardLayouts", targets: ["KeyboardLayouts"]),
        .library(name: "Installations", targets: ["Installations"]),
        .library(name: "VirtualHID", targets: ["VirtualHID"]),
        .library(name: "Helper", targets: ["Helper"]),
        .library(name: "Input", targets: ["Input"]),
        .library(name: "Doctor", targets: ["Doctor"]),
        .executable(name: "vhidd", targets: ["vhidd"]),
        .executable(name: "vhid", targets: ["vhid"]),
        .executable(name: "vhid-menubar", targets: ["vhid-menubar"]),
        .executable(name: "vhid-record", targets: ["vhid-record"]),
        .executable(name: "eyes", targets: ["eyes"]),
    ],
    // The dependencies stop at the leaf. Every library target below still links
    // nothing outside this package; what takes these is the CLI, which is the end of the
    // graph and nothing else's dependency. [LAW:one-way-deps]
    //
    // The argument parser, because a command's flags and the help that describes them
    // are one declaration there rather than a parser and a paragraph that drift apart.
    // [LAW:one-source-of-truth]
    //
    // The MCP SDK, because the protocol - its framing, its lifecycle, its method names -
    // is a specification this package has no business restating. Held to 0.12.x, because
    // below 1.0 a minor release is allowed to break the API.
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        // Named only because the SDK's `Transport` names its `Logger` type, which a
        // transport of this package's own has to say. The SDK already brings it in.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // The vocabulary at the seam between deciding what to type and typing it: a HID
        // usage, the modifiers held with it, and the two names one key goes by. It links
        // nothing, so neither the layout nor the device has to link the other to speak.
        // [LAW:one-way-deps]
        .target(name: "Keystrokes"),
        // The version the binaries report, stamped at build time from claude-plugin/VERSION
        // and git by the plugin, so no copy of the number is written down anywhere else.
        // It links nothing, so both halves' executables take it. [LAW:one-source-of-truth]
        .target(name: "Version", plugins: ["VersionStamp"]),
        .plugin(name: "VersionStamp", capability: .buildTool()),
        // The vocabulary stands on its own, so its tests do too: nothing here imports a
        // layout or a device. [LAW:decomposition]
        .testTarget(name: "KeystrokesTests", dependencies: ["Keystrokes"]),
        // The same seam for the mouse: a button, a count of motion, a move and a scroll.
        // Like Keystrokes it links nothing, so the device and the click decision share a
        // vocabulary without sharing a dependency. [LAW:one-way-deps]
        .target(name: "Pointing"),
        .testTarget(name: "PointingTests", dependencies: ["Pointing"]),
        // The one screen space both halves speak: a point, a box, how each is spelled, the
        // geometry of boxes, and the display layout. It links nothing of this package, so the
        // devices, the readers and the daemon's screen reader all stand on it without one
        // linking another. [LAW:one-source-of-truth] [LAW:one-way-deps]
        .target(name: "ScreenSpace"),
        .testTarget(name: "ScreenSpaceTests", dependencies: ["ScreenSpace"]),
        // The one read of that layout from the window server, apart from the values so what
        // only parses a layout - the daemon's wire, the devices' arithmetic - links no window
        // server. Linked by the processes that read it where they draw: vhidd's front-session
        // reader, vhid-record and eyes. [LAW:effects-at-boundaries]
        .target(name: "DisplayReading", dependencies: ["ScreenSpace"]),
        .testTarget(name: "DisplayReadingTests", dependencies: ["DisplayReading", "ScreenSpace"]),
        // Answering a signal rather than obeying it, for the daemon that has an ending of
        // its own to unwind through: a SIGTERM that killed it where it stood would leave a
        // key down on a device nothing is left to release. It links nothing.
        // [LAW:one-source-of-truth]
        .target(name: "Signals"),
        // Starting a child of this process, with what every child of vhidd needs - every
        // signal at its default and no descriptor it was not given - collecting one that
        // has ended, and running a command to its end, its deadline or its stop. Both halves
        // run their children here, the daemon's driver readings and the screen's capture and
        // grant reading alike, so every child is started, heard and stopped one way.
        // [LAW:single-enforcer] It links Telemetry, which links nothing, for the record of
        // what a stopped reading ended, so the screen half can stand on it. [LAW:one-way-deps]
        .target(name: "ChildProcess", dependencies: ["Telemetry"]),
        // Against /bin/sh as the child: what it was left holding, and what a signal does
        // to it under a parent that ignores that signal.
        .testTarget(name: "ChildProcessTests", dependencies: ["ChildProcess", "OwnThread"]),
        // Where the Karabiner-DriverKit-VirtualHIDDevice driver extension stands on this
        // Mac, and the four readings that answer is derived from. It links ChildProcess
        // for the commands those readings run and nothing else, so the CLI, the daemon and
        // scripts/virtual-hid-driver reach one vocabulary instead of three.
        // [LAW:one-source-of-truth]
        .target(name: "DriverExtension", dependencies: ["ChildProcess"]),
        // The verdict table is a pure function of four readings, so every combination is
        // exercised here - including the ones this Mac cannot be put into.
        .testTarget(name: "DriverExtensionTests", dependencies: ["DriverExtension", "ChildProcess", "OwnThread"]),
        // Carbon lives here and not in the device layer, so the privileged side that owns
        // the device never links a window server API. [LAW:one-way-deps]
        .target(name: "KeyboardLayouts", dependencies: ["Keystrokes"]),
        // The reverse map is built from a real layout's own data, so these read the
        // installed US and Dvorak layouts rather than a fixture that could agree with a
        // wrong reading of them.
        .testTarget(name: "KeyboardLayoutsTests", dependencies: ["KeyboardLayouts", "Keystrokes"]),
        // Which installation this is, as the one name every other name is built from -
        // an open set, so anything linking this package can run a daemon of its own
        // without a case being added here. It depends on nothing, so the root daemon and
        // the client both read it without either depending on the other.
        // [LAW:one-way-deps]
        .target(name: "Installations"),
        .testTarget(name: "InstallationsTests", dependencies: ["Installations"]),
        // Everything about the two virtual devices and nothing about what is typed on
        // them: the pqrs daemon socket, the two report layouts, and the keys and buttons
        // each device is holding. [LAW:one-way-deps]
        .target(name: "VirtualHID", dependencies: ["DriverExtension", "Keystrokes", "Pointing"]),
        // The wire protocol against a fake daemon on the other end of a socketpair, so
        // the framing is proven without root and without the driver.
        .testTarget(name: "VirtualHIDTests", dependencies: ["VirtualHID", "DriverExtension", "Keystrokes", "Pointing", "OwnThread"]),
        // What crosses the privilege boundary, and the client's side of it. It links the
        // two vocabularies and the screen space's values, for the displays it carries, and
        // nothing else: not the keyboard layout, because a root daemon must never read one,
        // not the display reading, because a root daemon reads the session in front only
        // through its reader there, and not the device, because a client must never open one.
        // [LAW:one-way-deps]
        .target(name: "Helper", dependencies: ["Installations", "Keystrokes", "Pointing", "ScreenSpace"]),
        .testTarget(name: "HelperTests", dependencies: ["Helper", "Installations", "Keystrokes", "Pointing", "ScreenSpace", "OwnThread"]),
        // What a caller asks the devices for, said in a caller's terms: text lowered to
        // keystrokes, a chord, a place on the screen to click. It links the two
        // vocabularies and the layout, and deliberately not Helper or VirtualHID: which
        // device answers is the caller's to pick, so this holds the protocols and the
        // caller supplies a conformance. [LAW:one-way-deps] [LAW:effects-at-boundaries]
        // Telemetry for the cause chain its stops are read by, so a record and a caller tell
        // a withdrawn run from a failed one by one rule. [LAW:single-enforcer]
        .target(name: "Input", dependencies: ["KeyboardLayouts", "Keystrokes", "Pointing", "ScreenSpace", "Telemetry"]),
        // The pointer's loop against a fake screen with an acceleration curve of its own,
        // and the typist against a keyboard that can be made to fail at the third keystroke
        // of four: no device, no window server, no grant.
        .testTarget(name: "InputTests", dependencies: ["Input", "KeyboardLayouts", "Keystrokes", "OwnThread", "Pointing", "ScreenSpace", "TestClock", "Telemetry"]),
        // What must hold before a verb can reach the devices, as a table from readings of
        // this Mac to a step for a person. The table reads nothing: every requirement is a
        // pure function of readings, so every combination is exercised in its tests,
        // including the ones this Mac cannot be put into. The probes that take the readings
        // sit beside it, each at its own edge, and `Readiness.read` is the one place they
        // are all taken. The CLI links it and the daemon does not - the daemon is what it
        // reads about, never a reader. Helper is for the one status call it asks the
        // daemon, over the same connection every verb dials. [LAW:one-way-deps]
        // [LAW:effects-at-boundaries]
        .target(name: "Doctor", dependencies: ["DriverExtension", "ChildProcess", "Installations", "Helper"]),
        .testTarget(name: "DoctorTests", dependencies: ["Doctor", "DriverExtension", "ChildProcess", "Installations", "Helper", "OwnThread"]),
        // What vhid's menu bar item shows, as a value built from doctor's readings and the
        // daemon's last failure, so every menu is one a test constructs. It reads nothing.
        // [LAW:effects-at-boundaries]
        .target(name: "MenuBar", dependencies: ["Doctor", "Helper", "Installations"]),
        .testTarget(name: "MenuBarTests", dependencies: ["MenuBar", "Doctor", "Helper", "Installations", "DriverExtension"]),
        // The menu bar item itself: AppKit, the readings, a click that copies a row, and the
        // set-up walk, which links DriverExtension for the one request it makes - the
        // driver's activation. Not a way to drive vhid, so it links no device vocabulary
        // and nothing that sends one. [LAW:one-way-deps]
        .executableTarget(name: "vhid-menubar", dependencies: ["MenuBar", "Doctor", "DriverExtension", "ChildProcess", "Helper", "Installations"]),
        // What `vhid record` and its tap app say over the socket between them, and the
        // app's watch on the command. It links nothing, so both ends speak one vocabulary
        // without either linking the other. [LAW:one-way-deps]
        .target(name: "RecordingTie"),
        .testTarget(name: "RecordingTieTests", dependencies: ["RecordingTie", "ChildProcess", "OwnThread"]),
        // The tap app `vhid record` launches, shipped as a signed bundle so Input
        // Monitoring can be granted to it once. It reads the tap and the I/O Registry and
        // hands the events to Input's `Recorder`; it never reaches the devices.
        // [LAW:effects-at-boundaries]
        .executableTarget(name: "vhid-record", dependencies: ["DisplayReading", "Input", "Keystrokes", "KeyboardLayouts", "Pointing", "RecordingTie", "ScreenSpace"]),
        // The root daemon that owns the devices. It links DriverExtension for the identity
        // the keyboard files its Keyboard Setup Assistant answer under, and deliberately
        // not KeyboardLayouts: text never reaches this process. [LAW:one-way-deps]
        // DisplayReading is for the reader it runs as a child in the session in front, the
        // one place this executable reads the layout.
        .executableTarget(
            name: "vhidd",
            dependencies: ["Helper", "VirtualHID", "DriverExtension", "ChildProcess", "DisplayReading", "Keystrokes", "Pointing", "ScreenSpace", "Signals", "Installations"]
        ),
        // The verbs, against the daemon over the helper connection - from a command line,
        // or as tools over MCP. It links Input for what the verbs mean and Helper for how
        // they get there, and deliberately not VirtualHID: a client never opens a device.
        // DriverExtension is for `vhid driver`, which reads the machine and not the
        // daemon, so scripts/virtual-hid-driver can ask it on a Mac with no daemon yet.
        // Doctor is for `vhid doctor`, which reads both and says what is left to do.
        // Seeing, EyesVerbs and Grants are the screen half, for `look` and doctor's grants:
        // this executable is the one place the halves meet. Telemetry and Turns link neither
        // half, so a call is recorded, and waits its turn, by the rule every unit is.
        // [LAW:one-way-deps]
        .executableTarget(
            name: "vhid",
            dependencies: [
                "Input", "Helper", "Installations", "KeyboardLayouts", "Keystrokes", "Pointing", "DriverExtension", "ChildProcess", "Doctor",
                "Version", "RecordingTie", "ScreenSpace", "Signals", "Telemetry", "Turns", "Seeing", "EyesVerbs", "Grants",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // The edge of the CLI: what argv becomes before any of it reaches a device, and
        // what the verbs report having done. The devices are fakes, so these run with no
        // daemon, no driver and no root.
        .testTarget(
            name: "vhidCLITests",
            dependencies: [
                "vhid", "Input", "Helper", "Installations", "Keystrokes", "Pointing", "Doctor", "DriverExtension", "Version", "OwnThread", "TestClock", "Signals",
                "Telemetry", "TelemetryTesting", "Turns", "Seeing", "EyesVerbs", "ScreenSpace", "RecordingTie",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        // The thread a test that waits is given, as a trait its suite names. A target of
        // its own because the suites that wait are in many test targets, and one test
        // target cannot link another. No product names it, so nothing shipped carries it.
        .target(name: "OwnThread", path: "Tests/OwnThread"),
        .testTarget(name: "OwnThreadTests", dependencies: ["OwnThread"]),
        // A clock that moves only when a test moves it or something sleeps on it, so a
        // verb that rests between reports is tested without waiting. A target of its own
        // for OwnThread's reason: InputTests, vhidCLITests and SeeingTests all sleep on it.
        .target(name: "TestClock", path: "Tests/TestClock"),
        // The authorization boundary of a root keystroke service, checked against the
        // test process's own identity and audit token: real code signing, no root.
        .testTarget(
            name: "vhiddTests",
            dependencies: ["vhidd", "Helper", "VirtualHID", "DriverExtension", "ChildProcess", "Keystrokes", "Pointing", "ScreenSpace", "Signals", "Installations", "OwnThread"]
        ),

        // eyes: the screen read, so input can be aimed - what is in front, where text is -
        // in the points the devices press. Its targets link nothing of the devices': no
        // device, no daemon, no input, and no device target links one of them. What links
        // both halves is the vhid executable, whose `look` reads with these and whose acts
        // press with those, and its tests. [LAW:one-way-deps] Both halves stand on Telemetry
        // and Turns, here under eyes/, and ChildProcess, ScreenSpace, DisplayReading and Version,
        // under Sources/, which link neither half.
        //
        // The vocabulary both readers speak and the protocol both conform to. It links the
        // screen space and its one layout read and nothing else - not Vision, not
        // ApplicationServices - so the tree and the pixels share one language without either
        // linking the other.
        .target(name: "Seeing", dependencies: ["DisplayReading", "ScreenSpace"], path: "eyes/Sources/Seeing"),
        // Every type there is a value, so the vocabulary is exercised with no display, no
        // capture and no grant. [LAW:effects-at-boundaries] The waits are kept on
        // a test's clock.
        .testTarget(name: "SeeingTests", dependencies: ["Seeing", "ScreenSpace", "TestClock"], path: "eyes/Tests/SeeingTests"),
        // The pixel reader: the grant, the capture and Vision. Its own target, so the
        // vocabulary stays linking nothing and the tree reader sits beside it unlinked.
        .target(name: "Pixels", dependencies: ["Seeing", "ScreenSpace", "Grants", "ChildProcess", "Telemetry", "Turns"], path: "eyes/Sources/Pixels"),
        // How a capture is cut into pieces and put back together, with no capture at all.
        .testTarget(name: "PixelsTests", dependencies: ["Pixels", "Seeing", "ScreenSpace", "Grants", "ChildProcess", "Turns"], path: "eyes/Tests/PixelsTests"),
        // The tree reader: the accessibility grant and the element reads, apart from Pixels
        // for the same reason.
        .target(name: "Tree", dependencies: ["Seeing", "ScreenSpace", "Grants"], path: "eyes/Sources/Tree"),
        // The element rules, the walk and the climb, over trees a test wrote.
        .testTarget(name: "TreeTests", dependencies: ["Tree", "Seeing", "ScreenSpace", "Grants"], path: "eyes/Tests/TreeTests"),
        // Whether the readers' grants are held and which app holds them: about the process,
        // not any reading, so apart from both readers, each of which asks it before looking.
        .target(name: "Grants", dependencies: ["Seeing", "ChildProcess", "Telemetry", "Responsibility"], path: "eyes/Sources/Grants"),
        // The libSystem calls tccd's attribution rests on, which the SDK has no header for:
        // a header of its own, so they are linked and type-checked, not looked up.
        .target(name: "Responsibility", path: "eyes/Sources/Responsibility"),
        .testTarget(name: "GrantsTests", dependencies: ["Grants", "Seeing", "Telemetry", "TelemetryTesting", "OwnThread"], path: "eyes/Tests/GrantsTests"),
        // One piece of work at a time, for what serves one: the daemon, and Vision. It links
        // neither half, so each half's gate is the same rule.
        .target(name: "Turns", path: "eyes/Sources/Turns"),
        .testTarget(name: "TurnsTests", dependencies: ["Turns"], path: "eyes/Tests/TurnsTests"),
        // One record per unit of work, and the one edge every record leaves a process by.
        // It links neither half, so both record through it. [LAW:nothing-unseen]
        .target(name: "Telemetry", path: "eyes/Sources/Telemetry"),
        // What every suite that runs units shares: a collector for their records, and the
        // trait that keeps them off the real edge.
        .target(name: "TelemetryTesting", dependencies: ["Telemetry"], path: "eyes/Tests/TelemetryTesting"),
        .testTarget(name: "TelemetryTests", dependencies: ["Telemetry", "TelemetryTesting"], path: "eyes/Tests/TelemetryTests"),
        // What each verb does and says, for the eyes command line and vhid's `look` alike,
        // so the two cannot come to answer differently. [LAW:one-source-of-truth] It links
        // the readers, and nothing of the devices' or of MCP's.
        .target(
            name: "EyesVerbs",
            dependencies: [
                "Seeing", "ScreenSpace", "Pixels", "Tree", "Grants", "Telemetry",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "eyes/Sources/Verbs"
        ),
        // The scope line is the sentence that licenses every narrow answer under it, so it
        // is checked here rather than read off a terminal. [LAW:verifiable-goals]
        .testTarget(
            name: "EyesVerbsTests",
            dependencies: ["EyesVerbs", "Seeing", "ScreenSpace", "Pixels", "Tree", "Grants", "Telemetry", "TelemetryTesting"],
            path: "eyes/Tests/EyesVerbsTests"
        ),
        // The eyes command line: the verbs, and the version every binary here is stamped with.
        // Version is the one root target an eyes target names, and it links nothing, so no
        // device target comes in under eyes through it. Named for its product, as a target
        // swiftbuild links with a `_main` must be. [LAW:one-way-deps]
        .executableTarget(
            name: "eyes",
            dependencies: ["EyesVerbs", "Telemetry", "Version", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "eyes/Sources/eyes"
        ),
    ]
)

// Every nonisolated async function runs on its caller's executor until it suspends, so a
// device call is in line on the `DeviceQueue` the moment it is asked for: calls asked in
// program order on one actor arrive in that order, with nothing scheduled in between.
// One setting for every target that compiles into the product (a plugin takes no settings), so a fake and the device it stands in for run the same way.
for target in package.targets where target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
}
