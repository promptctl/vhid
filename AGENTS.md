# AGENTS

## Before changing code

Read these README.md sections first; they are the source, not this file:

- [Two packages](README.md#two-packages) — `.` and `eyes/` are separate SwiftPM packages, kept apart on purpose.
- [Scope](README.md#scope) — what belongs in vhid and what does not.
- [Building](README.md#building) — build with `make`, not bare `swift build`, or the daemon refuses the binary.

A green `make test` at the root says nothing about `eyes/`. If you touched `eyes/`, run `cd eyes && swift build && swift test`.

<!-- BEGIN LIT INTEGRATION -->
## lit Agent-Native Workflow

This repository uses `lit` for agent-native issue tracking.

Start by running `lit quickstart` to load the workflow instructions. It prints how tickets are found, created, updated, and closed here, so running it first means the rest of your work follows the conventions this repo expects. It's a quick, read-only command — no need to check in before running it.

<!-- END LIT INTEGRATION -->
