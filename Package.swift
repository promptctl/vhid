// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vhid",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Keystrokes", targets: ["Keystrokes"]),
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
    ]
)
