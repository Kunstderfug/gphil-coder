# Persist the file-copy workflow queue across relaunch

Type: implementation
Status: resolved
Triage: ready-for-agent
Parent: PRD umbrella (Kunstderfug/gphil-coder#1)
Depends on: None

## What to build

The file-copy queue survives quitting and relaunching the app without any
manual action. Today the queue exists only in memory; only the copy form
fields (source roots, destination root, layout, filters) are persisted, and
saving a `.job` file is a separate manual act. A user who queues several
workflows for an overnight copy run loses the entire queue by restarting the
app (update, crash, or end of day).

Persist the queue automatically so that:

- every queue mutation (add, remove, clear, repair/relink, replace via job
  load) updates durable storage;
- at launch the queue is restored in order with stable workflow identities,
  destination layouts, filters, and extension selections;
- workflows whose folders no longer exist re-enter the existing NEEDS REPAIR
  flow and cannot run until relinked;
- a cleared queue stays cleared across relaunch (clear must persist; the queue
  must not resurrect);
- a restored queue is never auto-run; restoration is configuration only, and
  no workflow is marked running after relaunch.

Reuse the versioned `MediaCopyJobDocument` (v2) shape for the persisted
document so the queue and saved `.job` files share one semantics and one
version gate. Apply the existing rejection and repair behavior: decoding
completes before the in-memory queue is replaced; corrupt or future-version
documents are quarantined (prior bytes preserved, repairable error reported)
without discarding or corrupting anything else. Keep new persistence logic in
a small store or coordinator module, not the central view model.

## Current behavior (evidence, not contract)

- The queue is an in-memory `@Published` array on the media file coordinator;
  nothing writes it anywhere in the app lifecycle.
- Settings persistence stores copy form fields only — there is no key for the
  queue.
- Manual Save/Load Job exists with a versioned document format and a NEEDS
  REPAIR relink flow; this ticket reuses that machinery instead of inventing a
  second format.

## Ownership

| Behavior/state | Authoritative owner (module) | Platform input/output | Presentation-only state |
| --- | --- | --- | --- |
| Persisted queue document (versioned, atomic) | Copy queue persistence store | Application Support file read/write, corrupt-file quarantine | None |
| In-memory queue, repair issues, busy guard | Media file coordinator | Folder existence checks from the filesystem | Queue rows, NEEDS REPAIR badges |
| Relaunch restore timing (before UI binds) | App startup path | Launch-time file read | Status message on restore/quarantine |

## User actions

None — this is lifecycle behavior. Existing Add to Queue, Remove, Clear,
Repair, Save Job, and Load Job entry points keep their identities; they gain a
persistence side effect only.

## Acceptance criteria

- [ ] Store seam: each queue mutation produces a persisted document that a
      freshly initialized store decodes back to the identical queue (workflow
      IDs, order, source sets, destination root and layout, filter, extension
      and filename filters). Fails red today — no persistence exists.
- [ ] Relaunch seam: launching against a persisted document restores the
      queue; workflows with missing folders surface NEEDS REPAIR, are
      non-runnable, and relink repairs and persists.
- [ ] Clear and remove persist: a cleared or reduced queue is empty/reduced
      after relaunch, with no resurrection of removed workflows.
- [ ] Corruption gate: a corrupt or future-version persisted document yields
      an empty queue, a repairable status message, and the original file
      preserved (quarantined) — matching the `.job` rejection behavior.
- [ ] No auto-run: restoring a queue never starts a copy; nothing is marked
      running or in progress after relaunch.
- [ ] Restore never partially loads: decode completes before the in-memory
      queue is replaced; a failed decode leaves the current queue unchanged.
- [ ] Focused store and coordinator tests, existing copy suite still green,
      `git diff --check`.
- [ ] Manual signed-build smoke: queue two workflows, one on an SMB/NAS
      mount; quit; rename or unmount the folder; relaunch; confirm NEEDS
      REPAIR is offered and relinking works end to end.

## Blocked by

- None — can start immediately.

## Answer

Implemented at `873fd516fdeeecfeb1251800bba69ffe7d7a7d18` on
`ticket/001-persist-copy-workflow-queue-across-relaunch` (base `b2ed849`).

### Implementation summary

- `Sources/GPhilCoder/MediaCopyQueueStore.swift` (new): the one persistence
  owner. Reads/writes exactly one versioned `MediaCopyJobDocument` (v2, v1
  migrates, future versions rejected by the existing gate) with atomic
  writes and injectable `directoryURL`/`FileManager`. Corrupt or
  future-version documents are quarantined best-effort as a timestamped
  `.corrupt` sidecar (mirroring `SettingsPersistence.preserveCorruptBlob`)
  and never silently erased. Live location:
  `Application Support/GPhilCoder/MediaCopyQueue/MediaCopyQueue.json`.
- `Sources/GPhilCoder/MediaFileCoordinator.swift`: one persistence hook —
  `mediaCopyQueue` `didSet` (mirroring the rename-history `didSet`
  precedent) — plus restore-at-creation via the store's `LoadOutcome`
  (no document / restored / quarantined), guarded by
  `isRestoringMediaCopyQueue` so restore never re-saves. Restore is
  configuration only: nothing runs, no busy flag, no
  `currentMediaCopyWorkflowID`.
- `Sources/GPhilCoder/EncoderViewModel.swift`: composition only — creates the
  store at the injectable storage root (default live location) and threads it
  into the coordinator; init parks queue-restore/quarantine status during
  composition and surfaces it after `refreshFFmpeg()` so a corrupt queue's
  repairable message is never clobbered.
- `Sources/GPhilCoder/MediaCopyAppKitBoundary.swift` +
  `EncoderViewModel+MediaCopyActions.swift`: one injectable
  `repairDirectoryProvider` (default = unchanged production
  `chooseRepairDirectory` panel) so headless tests drive the real
  `repairMediaCopyWorkflow` entry point.

### Ownership

| Behavior/state | Authoritative owner (module) | Platform input/output | Presentation-only state |
| --- | --- | --- | --- |
| Persisted queue document | `MediaCopyQueueStore` | Application Support file I/O, quarantine sidecar | None |
| In-memory queue, repair issues, busy guard | `MediaFileCoordinator` | Filesystem folder checks | Queue rows, NEEDS REPAIR badges |
| Relaunch restore before UI binds | App composition (`EncoderViewModel` init) | Launch-time file read | Status message on restore/quarantine |

### Public-seam evidence (exact commands, at HEAD `873fd51`)

- Final gate: `swift test --filter MediaCopyQueuePersistenceTests` —
  10 tests, 0 failures. Composition-root cases: identical-queue restore
  (`testQueueMutationsPersistAndFreshModelRestoresIdenticalQueue`), remove
  and clear without resurrection, NEEDS REPAIR restore + real
  `repairMediaCopyWorkflow` relink persisted through a third fresh model,
  corrupt-document quarantine with exact repair-message prefix, future-version
  rejection, decode-before-replace, no-auto-run restore, load-job replacement
  through `loadMediaCopyJobData` + fresh composition, store v2 round trip.
- Coordinator isolation: `swift test --filter MediaFileManagerCoordinatorTests`
  — 19 tests, 0 failures; every composed model uses a per-test temporary
  queue root; no test resolves or deletes the live queue directory.
- Full suite: `swift test` — 255 tests, 0 failures; `git diff --check` clean.
- Red baseline: the frozen final-gate test bytes fail to compile at base
  `b2ed849` (`cannot find 'MediaCopyQueueStore' in scope`).
- Cold review: round 0 `changes_requested` (4 findings: live-queue purge in
  tests, repair status clobbered by init FFmpeg text, bypassed repair entry
  point, missing load-job seam) → one corrective commit closed all four →
  round 1 correction-only follow-up `approved` at `873fd51`
  (public_seam_proven, forbidden_work_proven).
- Residual: manual signed-build smoke (queue a workflow on an SMB/NAS mount,
  relaunch, relink) still pending release qualification.

### Run artifacts

Design authority bundles and run ledger:
`/Volumes/DEV/.gphil-runs/gphil-coder-ticket-001/` (v1 `d920e21c…cb6f0`,
v2 `7f43df02…629d`); review packets and results under
`/Volumes/DEV/.cold-review/gphil-coder-ticket-001-persist-copy-queue/`.
