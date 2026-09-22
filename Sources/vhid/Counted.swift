/// How many there were, and the noun agreeing with it: `1 character`, `2 characters`.
///
/// [LAW:single-enforcer] Small enough to write inline, and written inline it has already
/// been got wrong twice in this target - `typed 1 characters`, `after 1 motion reports` -
/// beside a third site that got it right. The rule is the same every time, so it is
/// stated once and the next verb gets it right without having to notice.
///
/// Regular plurals only, which is every noun these verbs count. A noun that pluralises
/// some other way does not belong here quietly: give it its own spelling at the call, so
/// the exception is visible rather than silently wrong. [LAW:no-silent-failure]
func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
