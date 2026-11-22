import Testing

extension Trait where Self == TimeLimitTrait {
    /// The bound on a whole test whose wait is the limit under test, which `hangGuard` cannot
    /// bound: a limit the code fails to keep would otherwise hold the run for good. A minute
    /// past the guard, so a wait the guard does bound fails first, as the `Hung` that names
    /// what it waited for. [LAW:one-source-of-truth] Derived from the guard, never guessed
    /// beside it.
    public static var hangLimit: Self { .timeLimit(.minutes(Int(hangGuard / .seconds(60)) + 1)) }
}
