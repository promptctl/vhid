# AGENTS

## Before changing code

Read these sections of [docs/development.md](docs/development.md) first; they are the source, not this file:

- [Two packages](docs/development.md#two-packages) — `.` and `eyes/` are separate SwiftPM packages, kept apart on purpose.
- [Scope](docs/development.md#scope) — a feature that reaches around the devices (clipboard, synthetic events, app APIs) needs an overwhelming case.
- [Building](docs/development.md#building) — at the root, use `make` and `make test`; bare `swift build` or `swift test` leaves the tree ad hoc signed and the daemon refuses it.

A green `make test` at the root says nothing about `eyes/`; its tests run separately, as the Two packages table shows.

<!-- BEGIN LIT INTEGRATION -->
## lit Agent-Native Workflow

This repository uses `lit` for agent-native issue tracking.

Start by running `lit quickstart` to load the workflow instructions. It prints how tickets are found, created, updated, and closed here, so running it first means the rest of your work follows the conventions this repo expects. It's a quick, read-only command — no need to check in before running it.

As you work a ticket, record its phase at each move: `lit phase <id> --to impl` when you start writing code, `lit phase <id> --to review` when its PR opens, `lit phase <id> --to merge` when review is done and the merge is under way. `lit start` puts it in `plan`, and `lit done <id>` ends it.

<!-- END LIT INTEGRATION -->
