import Foundation

/// A duration in the units the system's own waits take: Foundation's seconds, and
/// `poll`'s whole milliseconds. [LAW:one-source-of-truth] Said once, so no wait converts it
/// a way of its own.
extension Duration {
    public var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    public var wholeMilliseconds: Int32 {
        Int32(clamping: components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
