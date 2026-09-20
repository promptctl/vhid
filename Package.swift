// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vhid",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Keystrokes", targets: ["Keystrokes"]),
        .library(name: "Pointing", targets: ["Pointing"]),
        .library(name: "Signals", targets: ["Signals"]),
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
    ]
)
