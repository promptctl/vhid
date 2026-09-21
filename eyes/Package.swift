// swift-tools-version: 6.0
import PackageDescription

// A package of its own, and deliberately not a target in the repository root's manifest.
// eyes reads the screen; vhid drives the devices. Neither depends on the other in code,
// and the only thing joining them is the workflow a caller follows: eyes finds the
// coordinate, `vhid click` presses it. A target in the root manifest would be one
// `dependencies:` line away from linking them, and nothing in review catches that line.
// A sibling package cannot be reached from the root manifest at all, so the separation
// is structural rather than remembered. [LAW:one-way-deps]
let package = Package(
    name: "eyes",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Eyes", targets: ["Eyes"]),
    ],
    targets: [
        // The vocabulary both readers speak and the protocol both conform to. It links
        // nothing - not Vision, not ApplicationServices - so the tree and the pixels
        // share one language without either having to link the other.
        // [LAW:one-way-deps]
        .target(name: "Eyes"),
        // Every type here is a value, so the whole vocabulary is exercised with no
        // display, no capture and no accessibility grant. [LAW:effects-at-boundaries]
        .testTarget(name: "EyesTests", dependencies: ["Eyes"]),
    ]
)
