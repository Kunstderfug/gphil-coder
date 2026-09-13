# Report byte-level copy progress while large files transfer

Type: implementation
Status: open
Triage: ready-for-agent
Parent: PRD umbrella (Kunstderfug/gphil-coder#1)
Depends on: None

## What to build

Copy progress currently advances only at file boundaries: while one large
file transfers, the progress bar, current-file name, and byte totals are all
frozen. On a network drive a single multi-gigabyte media file can hold the UI
in one stale snapshot for many minutes, and the queue shows "Calculating
speed" until the first file commits because bytes are counted only after a
file finishes.

Make the published copy progress advance continuously while any single file
is transferring:

- cumulative copied bytes grow as data lands within the current file, not
  only when the file completes;
- the current file name is shown during its transfer;
- the final cumulative byte count still equals the planned total exactly;
- skipped-existing files continue to contribute zero bytes;
- cancellation and failure guarantees are unchanged: an interrupted transfer
  leaves no partial file at the destination and the transaction root is
  cleaned up as today;
- publication cadence is bounded (a small number of updates per second), not
  unbounded per chunk.

The transaction design must not regress: staging into the transaction root on
the destination volume, evidence capture, overwrite backups, rollback, and
atomic package handling all keep working. Packages, directories, extended
attributes, and metadata fidelity must survive byte-identical to the current
`copyItem`-based path — byte-reporting applies to large regular files; the
existing whole-item copy may remain in charge wherever byte progress cannot
be provided honestly (small files, packages), in which case those items
simply jump at their boundary as they do today.

A probe-based approach (observing the staged file's size on the destination
volume while the copy runs) is acceptable if it preserves copy fidelity; a
chunked writer must preserve the same end state. The ticket accepts either
implementation, judged only by the observable contract below.

## Current behavior (evidence, not contract)

- Whole-item `copyItem` is used per candidate; no byte-level callback exists.
- Progress is published before staging each file and after each commit, with
  cumulative bytes increased only after install — zero publications inside a
  file's transfer.
- The percentage is count-based; byte totals move only at file boundaries.

## Ownership

| Behavior/state | Authoritative owner (module) | Platform input/output | Presentation-only state |
| --- | --- | --- | --- |
| Byte progress sampling during transfer | Copy transaction executor | File size/bytes-written observation on the destination volume | None |
| Published progress snapshot (bytes, counts, current name) | Copy transaction executor via existing progress channel | None beyond existing publication | Progress bar, labels, current-file row |
| Transfer, staging, rollback, evidence | Existing copy transaction machinery | Filesystem copy/move/delete | None |

## User actions

None — this changes observation granularity of a running copy, not any entry
point. Start, Cancel, Queue, and Copy Now keep their identities.

## Acceptance criteria

- [ ] Executor seam (transaction suite, throttled/virtual slow copy in a real
      temp directory): while one large file is transferring, at least several
      progress publications occur with strictly increasing copied bytes, and
      intra-file bytes land before the next file begins. Fails red today —
      publications between file start and completion are zero.
- [ ] Final-byte gate: after a completed (non-cancelled) run, cumulative
      copied bytes equal the planned total exactly — intra-file reporting
      never over- or under-counts across the whole batch.
- [ ] Fidelity gate: a package and a file with extended attributes copied
      through the byte-reporting path end byte-identical (tree, checksums,
      attributes) to the current path; existing transaction tests pass
      unmodified.
- [ ] Skip gate: skipped-existing files contribute zero bytes and zero speed
      samples in published progress.
- [ ] Cancellation gate: cancelling mid-file leaves no partial file outside
      the transaction root and the staging root is removed, as today.
- [ ] Invalidation budget: intra-file ticks mutate only the published
      progress snapshot; the queue, plan, and scan state are untouched, and
      publication cadence is bounded (a test asserts a maximum publications
      per second within the chosen bound). Progress ticks must not invalidate
      structural workflow state or re-plan.
- [ ] Focused executor and coordinator tests, `git diff --check`.
- [ ] Manual signed-build smoke: copy a multi-GB file to an SMB/NAS share;
      progress bar and current-file name advance continuously; cancel
      mid-file; confirm no partial file at the destination.

## Blocked by

- None — can start immediately.
