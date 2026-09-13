# GPhil Coder — Ticket Map

Local Wayfinder-style tickets for Kunstderfug/gphil-coder. The product PRD
lives upstream as GitHub issue #1.

## Open tickets

- `001-persist-copy-workflow-queue-across-relaunch` — the file-copy queue
  survives quit/relaunch via an auto-persisted versioned document; clear
  stays clear; NEEDS REPAIR still gates missing folders; nothing auto-runs.
- `002-report-byte-level-copy-progress` — progress advances inside large
  file transfers (bounded cadence), with transaction, package, skip, and
  cancellation guarantees unchanged.
- `003-show-network-aware-copy-speed-and-byte-progress` — sliding-window
  current speed plus average, stalled state, and byte-based progress
  fraction. Depends on 002.
