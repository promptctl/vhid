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
        .executable(name: "eyes", targets: ["EyesCommand"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
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
        // The binary. Every line it prints describes the screen and the scope that was
        // looked at, which is what lets the reading below it be narrow and still be
        // trusted. [LAW:no-silent-failure]
        // Named for the directory and not for the binary: the product below is what is
        // called `eyes`, and a target of that name would collide with the `Eyes` module on
        // a case-insensitive filesystem, which is what macOS gives you by default.
        .executableTarget(
            name: "EyesCommand",
            dependencies: ["Eyes", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/Command"
        ),
        // The scope line is the sentence that licenses every narrow answer under it, so it
        // is checked here rather than read off a terminal by eye. [LAW:verifiable-goals]
        .testTarget(name: "EyesCommandTests", dependencies: ["EyesCommand", "Eyes"]),
    ]
)
