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
        .library(name: "Flavors", targets: ["Flavors"]),
        .library(name: "VirtualHID", targets: ["VirtualHID"]),
        .library(name: "HelperService", targets: ["HelperService"]),
        .executable(name: "vhidd", targets: ["vhidd"]),
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
        // Which installation this is: the one name every other name is built from. It
        // depends on nothing, so the root daemon and the client can both read it without
        // either depending on the other. [LAW:one-way-deps]
        .target(name: "Flavors"),
        .testTarget(name: "FlavorsTests", dependencies: ["Flavors"]),
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
        .target(name: "HelperService", dependencies: ["Flavors", "Keystrokes", "Pointing"]),
        .testTarget(name: "HelperServiceTests", dependencies: ["HelperService", "Flavors", "Keystrokes", "Pointing"]),
        // The root daemon that owns the devices. It links DriverExtension for the identity
        // the keyboard files its Keyboard Setup Assistant answer under, and deliberately
        // not KeyboardLayout: text never reaches this process. [LAW:one-way-deps]
        .executableTarget(
            name: "vhidd",
            dependencies: ["HelperService", "VirtualHID", "DriverExtension", "Keystrokes", "Pointing", "Signals", "Flavors"]
        ),
        // The authorization boundary of a root keystroke service, checked against the
        // test process's own identity and audit token: real code signing, no root.
        .testTarget(
            name: "vhiddTests",
            dependencies: ["vhidd", "HelperService", "VirtualHID", "DriverExtension", "Keystrokes", "Pointing", "Signals", "Flavors"]
        ),
    ]
)
