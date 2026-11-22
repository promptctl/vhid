import Darwin

/// A file descriptor this process opened and owns, closed when its owner goes, on every way
/// out of the scope that holds it, thrown errors included.
///
/// [LAW:types-are-the-program] Noncopyable, so a descriptor has one owner and is closed
/// once: a reading that left one open on some path, which a probe run every two seconds
/// would turn into the whole table within the minute, cannot be written. Made only from a
/// call that succeeded.
struct Descriptor: ~Copyable {
    let raw: Int32

    deinit {
        close(raw)
    }
}

/// The two ends of a pipe, each owned apart, so the writing end can go to a child while
/// the reading end stays.
struct Pipe: ~Copyable {
    let read: Descriptor
    let write: Descriptor
}
