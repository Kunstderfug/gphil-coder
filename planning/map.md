# GPhil Coder — Ticket Map

Local Wayfinder-style tickets for Kunstderfug/gphil-coder. The product PRD
lives upstream as GitHub issue #1.

## Open tickets

- `002-report-byte-level-copy-progress` — progress advances inside large
  file transfers (bounded cadence), with transaction, package, skip, and
  cancellation guarantees unchanged.
- `003-show-network-aware-copy-speed-and-byte-progress` — sliding-window
  current speed plus average, stalled state, and byte-based progress
  fraction. Depends on 002.
- `004-save-named-copy-queues-as-workflows` — named in-app library of
  saved File Copy queues that load back as the working workflow queue.
  Independent of 002/003. Does not replace ticket 001 last-session persist.

## Resolved

- `001-persist-copy-workflow-queue-across-relaunch` — resolved at
  `873fd51`: auto-persisted v2 queue document, restore-at-launch with NEEDS
  REPAIR gating, durable clear, quarantine + visible repair status; cold
  review approved.
