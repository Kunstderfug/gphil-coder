# Refactoring plan: EncoderViewModel decomposition

> **Status as of commit `65bb2fd`.** Update this file as each step lands.
> This document records what the 2026-07 code-review-driven refactor
> accomplished and what remains, so the next maintainer doesn't have to
> re-derive the sequencing decisions.

## Current status

- **Branch:** `main`, 6 commits ahead of `origin/main`.
- **Build:** clean. **Tests:** 124 pass (baseline before the refactor was 51).
- **No open correctness bugs** — all three Critical issues from the code review
  are closed.

### Review actions: completion

| # | Review action | Severity | Status |
|---|---------------|----------|--------|
| 1 | Temp-write-then-replace in `FFmpegEncoder` (truncated output on cancel/failure) | Critical | ✅ Done |
| 2 | Stale security-scoped bookmark fix | Critical | ✅ Done (absorbed into `BookmarkStore`) |
| 3 | Silent-decode hardening, all 4 persisted payloads | Critical | ✅ Done |
| 4 | God-Object decomposition of `EncoderViewModel` | Important | 🔶 ~15% done |
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

### Residual

`EncoderViewModel` is still **7,659 lines / 232 functions / 69 `didSet`
observers**. Only the security-scope/bookmark logic (~27 call sites) was
extracted. Four cohesive domains remain inside the class:

- **EncodingCoordinator** — `encodeTask`, `runJobs`, `startEncoding`/
  `cancelEncoding`, `confirmEncodingPreflight`, `JobResult`,
  `EncodingProgressReporter`.
- **FolderSyncCoordinator** — `folderSyncTask`, `runFolderSync`,
  `applyFolderSyncPlans`, `scheduleAutomaticFolderSync`,
  `runPendingFolderSyncIfNeeded`, `configureFolderSyncWatcher`.
- **MediaFileManager** — copy/delete/rename/undo-redo + `MediaFileInventory`
  (the largest remaining domain).
- **SettingsStore** — the 69 `@Published didSet → UserDefaults.standard`
  writes plus the `isLoadingPersistedSettings` guard dance.

---

## Why the easy-looking next steps are actually the hardest

Verified directly against the code; this evidence drives the step ordering:

- **`runJobs`** (the EncodingCoordinator core, `EncoderViewModel.swift:7427`)
  mutates `jobs` (a `@Published` array), flips `isEncoding`, clears
  `encodeTask`, and calls `securityScopes.stopEncoding()`,
  `notifyCompletionIfNeeded`, and `summarizeFFmpegOutput`.
  `EncodingProgressReporter` holds a `weak var model: EncoderViewModel?`.
- **`runFolderSync`** (`EncoderViewModel.swift:2792`) reads `syncFolderPairs`,
  `isFolderSyncBusy`, `folderSyncPendingAfterCurrentRun`, and calls
  `prepareFolderSyncFileAccess`, `securityScopes.stopSync()`, plus 6
  completion-path branches.
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

### Step 1 — Characterization tests for the coordinators (keystone)

**Risk:** lowest. **Leverage:** highest — this is what makes Steps 2–3 safe.

Before moving any coordinator code, lock current behavior with tests that
treat the view model as a black box against the real filesystem.
`EncoderViewModel` is instantiable in a test (it's `@MainActor`; the test
target already depends on `GPhilCoder`).

Add `Tests/GPhilCoderTests/EncodingCoordinatorTests.swift`:

- Build a view model, point it at a temp-dir output, feed it a tiny real
  `.wav` fixture, run `startEncoding()`, assert job states reach `.succeeded`
  and the output file exists. Gate on system `ffmpeg` with `XCTSkipUnless` so
  the suite stays green on ffmpeg-less machines.
- Assert `cancelEncoding()` mid-run leaves **no truncated output** (validates
  the Phase-1 temp-replace end-to-end).
- Assert the `existingOutputURLs` skip path and `-encoded` suffix integration.

Add `Tests/GPhilCoderTests/FolderSyncCoordinatorTests.swift`:

- Build two temp folder pairs, run `scanFolderSyncPlan()` then
  `syncFoldersNow()`, assert copied/updated/deleted counts match
  `FolderSyncPlanner` expectations.
- Assert re-running is a no-op; asserting a changed origin file triggers an
  update.

**Gate:** `swift test` green (124 existing tests + new ones).

### Step 2 — Extract `EncodingCoordinator` (medium risk)

Only after Step 1 lands.

New `Sources/GPhilCoder/EncodingCoordinator.swift`, `@MainActor`, owned by the
view model.

- **Moves in:** `runJobs`, `markJobRunning`, `encode(job:settings:)`,
  `apply(_:)`, `failureDiagnosticMessage`, `summarizeFFmpegOutput`,
  `updateJobProgress`, the `JobResult` enum, `EncodingProgressReporter`, and
  ownership of `encodeTask`.
- **The hard part — `jobs` and `isEncoding`:** these stay `@Published` on the
  view model (so the 34 `ContentView` bindings are untouched). The coordinator
  updates them via callback closures (`onJobsUpdate`, `onEncodingStateChange`,
  `onStatusMessage`); the view model's setters become thin forwarders. Public
  surface to `ContentView` is identical.
- `securityScopes.stopEncoding()` (called from `runJobs`) becomes a
  coordinator-injected callback: `coordinator.onReleaseScopes = { [weak self]
  in self?.securityScopes.stopEncoding() }`.
- `startEncoding`/`cancelEncoding`/`confirmEncodingPreflight` stay on the view
  model (they assemble `EncodingSettingsSnapshot` from 30+ settings) but
  delegate the run to `coordinator.run(jobs:settings:)`.

**Gate:** `swift build` + Step-1 tests still green. **Net:** ~250 lines out of
the view model; the encoding domain becomes testable in isolation via injected
mock callbacks.

### Step 3 — Extract `FolderSyncCoordinator` (medium risk)

Same shape as Step 2. New `Sources/GPhilCoder/FolderSyncCoordinator.swift`.

- **Moves in:** `runFolderSync`, `applyFolderSyncPlans`,
  `scheduleAutomaticFolderSync`, `runPendingFolderSyncIfNeeded`,
  `configureFolderSyncWatcher`, ownership of `folderSyncTask`/
  `folderSyncAutoTask`/`folderSyncWatcher`/`folderSyncPendingAfterCurrentRun`.
- `syncFolderPairs`, `isSyncing`, `isFolderSyncWatching`, the `sync*Count`
  `@Published` values stay on the view model, updated via callbacks.
- Reuses the already-extracted `securityScopes` and `bookmarks` collaborators.

**Gate:** `swift build` + Step-1 tests still green. **Net:** ~400 more lines
out.

### Step 4 — `SettingsStore` (DEFER)

**Recommendation: do not attempt now.**

The 69 `didSet → UserDefaults` writes are the review's other target, but
extracting them means either:

- exposing a `@Published var settings: SettingsStore` and rewiring 34
  `$model.*` bindings to `$model.settings.*` across the untested 3,909-line
  `ContentView` — high risk; or
- leaving the `@Published` properties on the view model as computed forwards
  into the store — works but gains little (the `didSet` observers still exist,
  just forwarding).

The dual-persistence drift risk this addresses is **already mitigated** by the
Phase-3 versioned-decode work (`VersionedBlob` + `DecodeProblem` surfacing).
Revisit only after `ContentView` has widget-test coverage — a separate, large
effort outside this plan's scope.

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

## Open sequencing question

Step 1 is the keystone — it's what makes Steps 2–3 safe. But it adds a test
dependency on system `ffmpeg` (gated with `XCTSkipUnless`).

- **Option A (recommended):** Do Step 1 first as its own PR, then Steps 2 and 3
  each as separate PRs. Slowest but safest; each PR is independently
  revertible and the test net grows before the risky surgery.
- **Option B:** Skip Step 1, do Steps 2–3 carefully with only the existing 124
  tests as the net. Faster, but a regression in `runJobs` or `runFolderSync`
  could land undetected since nothing currently exercises those paths headless.

**Recommendation: Option A.**
