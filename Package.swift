// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vhid",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Keystrokes", targets: ["Keystrokes"]),
        .library(name: "Pointing", targets: ["Pointing"]),
        .library(name: "Signals", targets: ["Signals"]),
        .library(name: "DriverExtension", targets: ["DriverExtension"]),
        .library(name: "KeyboardLayout", targets: ["KeyboardLayout"]),
        .library(name: "Installations", targets: ["Installations"]),
        .library(name: "VirtualHID", targets: ["VirtualHID"]),
        .library(name: "Helper", targets: ["Helper"]),
        .library(name: "Input", targets: ["Input"]),
        .library(name: "Doctor", targets: ["Doctor"]),
        .executable(name: "vhidd", targets: ["vhidd"]),
        .executable(name: "vhid", targets: ["vhid"]),
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
        // The vocabulary stands on its own, so its tests do too: nothing here imports a
        // layout or a device. [LAW:decomposition]
        .testTarget(name: "KeystrokesTests", dependencies: ["Keystrokes"]),
        // The same seam for the mouse: a button, a count of motion, a move and a scroll.
        // Like Keystrokes it links nothing, so the device and the click decision share a
        // vocabulary without sharing a dependency. [LAW:one-way-deps]
        .target(name: "Pointing"),
        .testTarget(name: "PointingTests", dependencies: ["Pointing"]),
        // Answering a signal rather than obeying it, for the daemon that has an ending of
        // its own to unwind through: a SIGTERM that killed it where it stood would leave a
        // key down on a device nothing is left to release. It links nothing.
        // [LAW:one-source-of-truth]
        .target(name: "Signals"),
        // Where the Karabiner-DriverKit-VirtualHIDDevice driver extension stands on this
        // Mac, and the four readings that answer is derived from. It links nothing, so the
        // CLI, the daemon and scripts/virtual-hid-driver reach one vocabulary instead of
        // three. [LAW:one-source-of-truth]
        .target(name: "DriverExtension"),
        // The verdict table is a pure function of four readings, so every combination is
        // exercised here - including the ones this Mac cannot be put into.
        .testTarget(name: "DriverExtensionTests", dependencies: ["DriverExtension"]),
        // Carbon lives here and not in the device layer, so the privileged side that owns
        // the device never links a window server API. [LAW:one-way-deps]
        .target(name: "KeyboardLayout", dependencies: ["Keystrokes"]),
        // The reverse map is built from a real layout's own data, so these read the
        // installed US and Dvorak layouts rather than a fixture that could agree with a
        // wrong reading of them.
        .testTarget(name: "KeyboardLayoutTests", dependencies: ["KeyboardLayout", "Keystrokes"]),
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
        .testTarget(name: "VirtualHIDTests", dependencies: ["VirtualHID", "DriverExtension", "Keystrokes", "Pointing"]),
        // What crosses the privilege boundary, and the client's side of it. It links the
        // two vocabularies and nothing else: not the layout, because a root daemon must
        // never read one, and not the device, because a client must never open one.
        // [LAW:one-way-deps]
        .target(name: "Helper", dependencies: ["Installations", "Keystrokes", "Pointing"]),
        .testTarget(name: "HelperTests", dependencies: ["Helper", "Installations", "Keystrokes", "Pointing"]),
        // What a caller asks the devices for, said in a caller's terms: text lowered to
        // keystrokes, a chord, a place on the screen to click. It links the two
        // vocabularies and the layout, and deliberately not Helper or VirtualHID: which
        // device answers is the caller's to pick, so this holds the protocols and the
        // caller supplies a conformance. [LAW:one-way-deps] [LAW:effects-at-boundaries]
        .target(name: "Input", dependencies: ["KeyboardLayout", "Keystrokes", "Pointing"]),
        // The pointer's loop against a fake screen with an acceleration curve of its own,
        // and the typist against a keyboard that can be made to fail at the third keystroke
        // of four: no device, no window server, no grant.
        .testTarget(name: "InputTests", dependencies: ["Input", "KeyboardLayout", "Keystrokes", "Pointing"]),
        // What must hold before a verb can reach the devices, as a table from readings of
        // this Mac to a step for a person. It reads nothing itself: every requirement is a
        // pure function of readings taken at the edge, so every combination is exercised
        // in its tests, including the ones this Mac cannot be put into. The CLI links it
        // and the daemon does not - the daemon is what it reads about, never a reader.
        // Helper is for the one status call it asks the daemon, over the same connection
        // every verb dials. [LAW:one-way-deps] [LAW:effects-at-boundaries]
        .target(name: "Doctor", dependencies: ["DriverExtension", "Installations", "Helper"]),
        .testTarget(name: "DoctorTests", dependencies: ["Doctor", "DriverExtension", "Installations", "Helper"]),
        // The root daemon that owns the devices. It links DriverExtension for the identity
        // the keyboard files its Keyboard Setup Assistant answer under, and deliberately
        // not KeyboardLayout: text never reaches this process. [LAW:one-way-deps]
        .executableTarget(
            name: "vhidd",
            dependencies: ["Helper", "VirtualHID", "DriverExtension", "Keystrokes", "Pointing", "Signals", "Installations"]
        ),
        // The verbs, against the daemon over the helper connection - from a command line,
        // or as tools over MCP. It links Input for what the verbs mean and Helper for how
        // they get there, and deliberately not VirtualHID: a client never opens a device.
        // DriverExtension is for `vhid driver`, which reads the machine and not the
        // daemon, so scripts/virtual-hid-driver can ask it on a Mac with no daemon yet.
        // Doctor is for `vhid doctor`, which reads both and says what is left to do.
        // [LAW:one-way-deps]
        .executableTarget(
            name: "vhid",
            dependencies: [
                "Input", "Helper", "Installations", "KeyboardLayout", "Keystrokes", "Pointing", "DriverExtension", "Doctor",
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
                "vhid", "Input", "Helper", "Installations", "Keystrokes", "Pointing",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        // The authorization boundary of a root keystroke service, checked against the
        // test process's own identity and audit token: real code signing, no root.
        .testTarget(
            name: "vhiddTests",
            dependencies: ["vhidd", "Helper", "VirtualHID", "DriverExtension", "Keystrokes", "Pointing", "Signals", "Installations"]
        ),
    ]
)
