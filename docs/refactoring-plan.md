# Refactoring plan: EncoderViewModel decomposition

> **Status after the `SettingsPersistence` extraction slice.** Update this file
> as each step lands.
> This document records what the 2026-07 code-review-driven refactor
> accomplished and what remains, so the next maintainer doesn't have to
> re-derive the sequencing decisions.

## Current status

- **Branch:** `main`, one local implementation commit ahead of `origin/main`.
- **Build:** clean. **Tests:** 146 pass (baseline before the refactor was 51).
- **No open correctness bugs** — all three Critical issues from the code review
  are closed.

### Review actions: completion

| # | Review action | Severity | Status |
|---|---------------|----------|--------|
| 1 | Temp-write-then-replace in `FFmpegEncoder` (truncated output on cancel/failure) | Critical | ✅ Done |
| 2 | Stale security-scoped bookmark fix | Critical | ✅ Done (absorbed into `BookmarkStore`) |
| 3 | Silent-decode hardening, all 4 persisted payloads | Critical | ✅ Done |
| 4 | God-Object decomposition of `EncoderViewModel` | Important | 🔶 Steps 1-6 done; restore orchestration still pending |
| 5 | Move `RestorePlanner` to `GPhilCoderCore` | Important | ✅ Done |
| 6 | Move FFmpeg pure functions to `GPhilCoderCore` | Important | ✅ Done |

### What landed

New `GPhilCoderCore` (Foundation-only, unit-tested) files:

- `RestorePlanner.swift` — moved from the App target; 16 types made public.
- `FFmpegArguments.swift` — pure argument builders, parsers, and shared error
  types (`FFmpegToolError`, `EncodeSkipError`, `FFmpegProgressSnapshot`,
  `MultichannelSplitOptions`, `ffmpegCodecArguments`, `ffmpegChannelGroups`,
  `ffmpegPanFilter`, `parseAudioChannelCount`, …).
- `FilePathTransactions.swift` — `availableDestinationURL`, `moveRenameFile`
  (case-only-rename temp+rollback), `encodedOutputFileName`.
- `VersionedBlob.swift` — shared versioned-decode helper (`DecodeProblem`,
  `VersionedBlob.decode`/`.encode`/`.decodeEnvelope`) with legacy bare-array
  fallback for backward compatibility.

New `GPhilCoder` (App) files:

- `SecurityScopeManager.swift` — owns the two `[URL]` scope buckets
  (encoding + folder-sync) and the pure path helpers (`uniqueURLs`,
  `sameFileURL`, `containsFileURL`, `canWriteTemporaryFile`).
- `BookmarkStore.swift` — bookmark create/resolve; `resolveSecurityScopedBookmark`
  now surfaces `isStale` via an `onStale` closure so stale bookmarks get
  re-issued instead of silently failing.
- `EncodingCoordinator.swift` — owns the encoding run loop, child process
  registry, job result application, FFmpeg progress reporting, and completion
  messaging callbacks while `EncoderViewModel` keeps the published UI surface.
- `FolderSyncCoordinator.swift` — owns the folder-sync scan/apply run loop,
  auto-sync debounce, FSEvents watcher, pending rerun flag, and completion
  messaging callbacks while `EncoderViewModel` keeps the published UI surface.
- `MediaFileCoordinator.swift` — owns media file-management UI state, media copy
  scan, immediate copy execution, queued copy execution, media inventory
  scan/cache coordination, delete/rename preview rebuilds, and shared
  file-management cancellation.
- `MediaFileCoordinatorTypes.swift` — shared file-management result, trash,
  and rename-history DTOs used by the coordinator and view model.
- `MediaFileCoordinator+State.swift` — coordinator-owned derived media state,
  selected-extension/configuration helpers, inventory mutation, and rename
  history stack management.
- `MediaFileCoordinator+ManagedOperations.swift` — owns filtered delete
  execution, filtered rename execution, rename undo/redo execution, media
  filename-filter debounce, managed-operation progress/status updates, and
  completion callbacks. `EncoderViewModel` keeps compatibility accessors, entry
  points, panels/prompts, trash ledger hooks, settings persistence writes, and
  completion notifications.
- `SettingsPersistence.swift` — owns `UserDefaults` key constants,
  scalar/default read-write helpers, directory and UUID persistence,
  media-copy source-root path persistence, media rename settings/history
  encode/decode, and corrupt-blob sidecar preservation. `EncoderViewModel`
  keeps the SwiftUI-bound `@Published` settings surface.

Step 1 characterization coverage:

- `Tests/GPhilCoderTests/EncodingCoordinatorTests.swift` — black-box tests for
  successful audio encoding, existing-output skip behavior with the same-format
  `-encoded` suffix, mixed skip/success runs, cancellation preserving an
  existing output file, and cancellation marking queued work as cancelled.
- `Tests/GPhilCoderTests/FolderSyncCoordinatorTests.swift` — black-box tests for
  scan/sync copy-update-delete counts, no-op reruns, and update detection after
  an origin file changes, plus disabled-pair filtering, custom extension
  filtering, filtered deletes, and overwrite-off skips.
- `Tests/GPhilCoderTests/AsyncTestSupport.swift` — shared async polling and
  `UserDefaults` cleanup for view-model tests.
- `Tests/GPhilCoderTests/MediaFileManagerCoordinatorTests.swift` — black-box
  tests for media copy scan filtering, no-conflict copy execution, destination
  conflict detection, delete preview inventory use across multiple source
  roots, rename preview rebuilds, and rename conflict blocking.
- `Tests/GPhilCoderTests/EncoderViewModelPersistenceTests.swift` — view-model
  persistence characterization for encoding settings, HEVC/video load order,
  folder-sync settings, media copy settings, media rename settings/history, and
  selected preset normalization.

The cancellation characterization test exposed an extra coordinator bug:
`cancelEncoding()` cancelled the parent task but did not reliably terminate
already-starting FFmpeg child processes. `FFmpegTool` now supports a
run-scoped `ProcessRegistry`, and `EncodingCoordinator` resets/terminates that
registry around each encode run so cancelled encodes do not replace existing
outputs.

### Residual

`EncoderViewModel` is still large (about 5,690 lines) with many `didSet`
observers. The security-scope/bookmark logic (~27 call sites), encoding run
loop, folder-sync run loop, media file-management state/execution, and
settings persistence primitives are extracted. The remaining view-model code is
mostly entry/configuration wrappers plus two larger domains:

- **Encoding entry/preflight** — `startEncoding`/`cancelEncoding`/
  `confirmEncodingPreflight` still live on the view model because they assemble
  `EncodingSettingsSnapshot` from UI-bound settings and request file access,
  then delegate execution to `EncodingCoordinator`.
- **Folder sync entry/configuration** — `scanFolderSyncPlan`/`syncFoldersNow`/
  `cancelFolderSync` and `configureFolderSyncWatcher` stay as thin wrappers.
  Folder validation, bookmark authorization, persistence, and collision checks
  remain on the view model because they interact with UI prompts and stored
  `syncFolderPairs`; execution delegates to `FolderSyncCoordinator`.
- **MediaFileManager entry/integration** — source/destination panels, queue/job
  document save/load, prompt construction, trash/rename persistence hooks, and
  compatibility accessors remain on the view model while state and execution
  live in `MediaFileCoordinator`.
- **SettingsStore** — a full state-owning store is still deferred. The
  persistence helper is extracted, but the `@Published didSet` hooks and
  `isLoadingPersistedSettings` load-order guard remain on `EncoderViewModel`
  so `ContentView` bindings stay stable.

---

## Why the easy-looking next steps are actually the hardest

Verified directly against the code; this evidence drives the step ordering:

- **`runJobs`** is now in `EncodingCoordinator.swift`. `jobs` and `isEncoding`
  remain `@Published` on `EncoderViewModel`; the coordinator updates them via
  injected closures and calls back for security-scope release, status text, and
  completion notifications.
- **`runFolderSync`** is now in `FolderSyncCoordinator.swift`. `syncFolderPairs`,
  `isSyncing`, `isFolderSyncWatching`, `syncPlan`, `syncProgress`, and the
  scan counts remain `@Published` on `EncoderViewModel`; the coordinator
  updates them through callbacks and calls back for folder validation,
  bookmark/file access, scope release, and completion notifications.
- **`ContentView` binds 34 `@Published` properties via `$model.*` two-way
  bindings** (`$model.mp3Mode`, `$model.overwriteExisting`, …) across the
  3,909-line view, which has **no widget tests**.

So a "clean" extraction means either moving `@Published` state off the view
model (breaking 34 SwiftUI bindings, untested) or passing the view model back
into the coordinator (re-creating the coupling). Neither is low-risk. The
honest path is to **buy down the risk with tests first**, then extract.

---

## Plan for the remaining decomposition

Risk-ordered. Each step is independently revertible. Gate every step with
`swift build` + the tests named below staying green.

### Step 1 — Characterization tests for the coordinators (keystone) — DONE

**Risk:** lowest. **Leverage:** highest — this is what makes Steps 2–3 safe.

Before moving any coordinator code, lock current behavior with tests that
treat the view model as a black box against the real filesystem.
`EncoderViewModel` is instantiable in a test (it's `@MainActor`; the test
target already depends on `GPhilCoder`).

Added `Tests/GPhilCoderTests/EncodingCoordinatorTests.swift`:

- Builds a view model, points it at a temp-dir output, feeds it a tiny real
  `.wav` fixture, runs `startEncoding()`, and asserts job state reaches
  `.succeeded` and the output file exists. Gated on system `ffmpeg` with
  `XCTSkip`.
- Asserts `cancelEncoding()` mid-run leaves an existing output untouched
  (validates the Phase-1 temp-replace end-to-end).
- Asserts the existing-output skip path and `-encoded` suffix integration.
- Asserts mixed skip/success runs keep per-job state correct.
- Asserts queued jobs become `.cancelled` when a single-worker run is cancelled.

Added `Tests/GPhilCoderTests/FolderSyncCoordinatorTests.swift`:

- Builds temp folder pairs, runs `scanFolderSyncPlan()` then
  `syncFoldersNow()`, and asserts copied/updated/deleted counts match
  `FolderSyncPlanner` expectations.
- Asserts re-running is a no-op, and a changed origin file triggers an update.
- Asserts disabled pairs are ignored.
- Asserts custom extension filters copy/delete only matching extensions.
- Asserts overwrite-off sync skips existing destination files without replacing
  them.

**Gate:** `swift test` green (134 tests).

### Step 2 — Extract `EncodingCoordinator` (medium risk) — DONE

Added `Sources/GPhilCoder/EncodingCoordinator.swift`, `@MainActor`, owned by the
view model.

- **Moves in:** `runJobs`, `markJobRunning`, `encode(job:settings:)`,
  `apply(_:)`, `failureDiagnosticMessage`, `summarizeFFmpegOutput`,
  `updateJobProgress`, the `JobResult` enum, `EncodingProgressReporter`, and
  ownership of `encodeTask`.
- **The hard part — `jobs` and `isEncoding`:** these stayed `@Published` on the
  view model (so the 34 `ContentView` bindings are untouched). The coordinator
  updates them via callback closures (`setJobs`, `setEncodingState`,
  `setStatusMessage`); the view model's setters are closure-backed. Public
  surface to `ContentView` is identical.
- `securityScopes.stopEncoding()` (called from `runJobs`) becomes a
  coordinator-injected `releaseScopes` callback.
- `startEncoding`/`cancelEncoding`/`confirmEncodingPreflight` stay on the view
  model (they assemble `EncodingSettingsSnapshot` from 30+ settings) but
  delegate the run to `encodingCoordinator.start(jobs:settings:)` and
  `encodingCoordinator.cancel()`.

**Gate:** `swift build` + Step-1 tests green. **Net:** ~200 lines out of
the view model; the encoding domain becomes testable in isolation via injected
mock callbacks.

### Step 3 — Extract `FolderSyncCoordinator` (medium risk) — DONE

Same shape as Step 2. Added `Sources/GPhilCoder/FolderSyncCoordinator.swift`.

- **Moves in:** `runFolderSync`, `applyFolderSyncPlans`,
  `scheduleAutomaticFolderSync`, `runPendingFolderSyncIfNeeded`,
  `configureFolderSyncWatcher`, ownership of `folderSyncTask`/
  `folderSyncAutoTask`/`folderSyncWatcher`/`folderSyncPendingAfterCurrentRun`.
- `syncFolderPairs`, `isSyncing`, `isFolderSyncWatching`, the `sync*Count`
  `@Published` values stayed on the view model, updated via callbacks.
- Reuses the already-extracted `securityScopes` and `bookmarks` collaborators.

**Gate:** `swift build` + Step-1 tests green. **Net:** ~300 more lines
out.

### Step 4 — Characterize `MediaFileManager` view-model behavior — DONE

Added `Tests/GPhilCoderTests/MediaFileManagerCoordinatorTests.swift` as a
black-box safety net before extracting the largest remaining domain.

- Covers media copy scan filtering by selected extension and file-name query.
- Covers no-conflict filtered copy into nested destination folders without
  invoking conflict UI.
- Covers destination conflict detection without mutating existing files.
- Covers delete preview rebuilding from inventory across multiple source roots.
- Covers rename preview rebuilding when settings change.
- Covers rename conflict previews blocking apply.

Headless gaps remain for overwrite/skip conflict application, filtered
delete-to-Trash, rename apply, undo, and redo because those paths currently
cross `NSAlert` confirmation and/or macOS Trash behavior.

**Gate:** `swift test --filter MediaFileManagerCoordinatorTests` green, then
full `swift test` green (141 tests).

### Step 5 — Extract `MediaFileCoordinator` (medium-high risk) — DONE

`Sources/GPhilCoder/MediaFileCoordinator.swift`,
`Sources/GPhilCoder/MediaFileCoordinator+State.swift`,
`Sources/GPhilCoder/MediaFileCoordinatorTypes.swift`, and
`Sources/GPhilCoder/MediaFileCoordinator+ManagedOperations.swift` now own
media file-management state, `scanMediaCopyFiles()`, immediate
`copyFilteredMediaFiles()` execution, queued copy execution, media inventory
scanning, delete/rename preview rebuilds, filtered delete execution, filtered
rename execution, rename undo/redo execution, media filename-filter debounce,
`mediaCopyTask`, and `mediaFileNameFilterRefreshTask`.

The split keeps coordinator source files under 1,000 lines. Unlike the earlier
Steps 2-3 shape, `MediaFileCoordinator` is now an `ObservableObject` that owns
plans, progress, busy flags, queue state, selected media settings, rename
settings, and rename history stacks. `EncoderViewModel` forwards object changes
for compatibility and keeps the public SwiftUI-bound entry points, validation
alert, conflict/trash/rename prompt construction, trash ledgers, panel
interactions, queue/input mutation callbacks, settings persistence writes, and
completion notification hook.

- **Moved in:** media file inventory scan/cache, delete/rename preview
  rebuilds, copy scan/copy run loop, queued copy run loop, filtered delete run
  loop, filtered rename run loop, rename undo/redo run loop, media
  filename-filter debounce, `mediaCopyTask`, `mediaFileNameFilterRefreshTask`,
  media copy/rename/delete status helpers, media file-management published
  state, selected-extension/configuration helpers, and rename history stack
  mutation.
- **Still move in:** none for this step.
- **Keep on the view model for now:** `NSOpenPanel`/`NSSavePanel` and `NSAlert`
  construction, queue/job document save/load, queue/input mutation callbacks,
  trash ledger persistence hooks, completion notifications, and settings writes
  that still interact with `isLoadingPersistedSettings`.
- **Wire via callbacks:** status messaging, prompt callbacks for
  conflict/trash/rename confirmation, persistence hooks for trash ledgers and
  rename history, and side-effect hooks for removing or restoring queue inputs.

**Gate:** `swift build` + `MediaFileManagerCoordinatorTests` + full
`swift test` green.

### Step 6 — `SettingsPersistence` first; full `SettingsStore` still DEFER

**Recommendation: do not attempt now.**

The 48 `didSet → UserDefaults` writes are the review's other target, but a
full state-owning extraction means either:

- exposing a `@Published var settings: SettingsStore` and rewiring 34
  `$model.*` bindings to `$model.settings.*` across the untested 3,909-line
  `ContentView` — high risk; or
- leaving the `@Published` properties on the view model as computed forwards
  into the store — works but gains little (the `didSet` observers still exist,
  just forwarding).

The dual-persistence drift risk this addresses is **already mitigated** by the
Phase-3 versioned-decode work (`VersionedBlob` + `DecodeProblem` surfacing).

Safer preliminary step: extract a `SettingsPersistence` helper that owns
`UserDefaults` key access, scalar read/write helpers, directory/UUID helpers,
and JSON blob encode/decode, while leaving every `@Published` property and
side-effecting `didSet` on `EncoderViewModel`. Attempt that only after adding
view-model persistence characterization tests for encoding settings,
HEVC/video load order, folder-sync settings, media copy settings, media rename
settings/history, and preset selection normalization.

Revisit full `SettingsStore` only after `ContentView` has widget-test coverage
— a separate, large effort outside this plan's scope.

---

## What headless coverage cannot verify

Steps 2 and 3 change runtime behavior that the SwiftPM test environment can
only partially exercise (real `ffmpeg`, real security scopes, real FSEvents).
After each step, run the manual smoke-tests listed in
`Tests/GPhilCoderTests/TESTING.md`:

1. Encode a file; cancel mid-encode; confirm no truncated output.
2. Authorize a folder-sync pair, rename the watched folder, confirm auto-sync
   still resolves (stale-bookmark refresh).
3. Encode into a security-scoped export folder; confirm the scope is released
   on finish.
4. Cancel an encode; confirm no orphaned security scope.

The conversion-path scripts (`scripts/test_audio_conversions.sh`,
`scripts/test_video_conversions.sh`) cover the ffmpeg behavior end-to-end.

---

## Current next step

The original sequencing question is resolved: characterization coverage landed
first, then the encoding, folder-sync, media-file, and settings-persistence
boundaries were extracted.

The next implementation slice should be `RestoreCoordinator`, because restore
planning/apply/export orchestration is the largest coherent domain still
inside `EncoderViewModel`. Keep `ContentView` bindings stable and avoid a full
`SettingsStore` until widget or UI coverage exists around the current binding
surface.
