# Refactoring implementation summary

This summarizes the current state of the `EncoderViewModel` decomposition after
the restore coordinator and SwiftUI binding-surface slice.

## Current status

- `main` is two local implementation commits ahead of `origin/main` after this
  slice.
- `swift test` passes locally: 150 tests, 0 failures.
- The critical correctness fixes from the original review are closed.
- The implementation is in a healthy intermediate state: execution-heavy logic
  restore orchestration, and settings persistence plumbing have moved out of
  `EncoderViewModel`, but prompts and authorization still keep the view model
  large.

## Implemented

- `EncodingCoordinator` owns the encoding run loop, child process registry,
  cancellation, job state application, progress reporting, scope release
  callback, and completion notification callback.
- `FolderSyncCoordinator` owns folder-sync scan/apply, auto-sync debounce,
  watcher lifecycle, pending reruns, progress, cancellation, and completion
  callbacks.
- `MediaFileCoordinator` owns media file-management state and most execution:
  copy scans, immediate copy, queued copy, inventory scans, delete previews,
  rename previews, filtered delete, filtered rename, undo/redo, progress, busy
  flags, selected media settings, queue state, and rename history.
- `GPhilCoderCore` now contains pure, Foundation-only planning and helper code:
  restore planning, FFmpeg argument helpers, file path transactions, and
  versioned blob decoding.
- `SettingsPersistence` owns `UserDefaults` keys, scalar/default helpers,
  directory and UUID helpers, media rename settings/history blob
  encode/decode, media copy source-root persistence, and corrupt-blob sidecar
  preservation. The view model still owns SwiftUI-bound `@Published` state.
- `RestoreCoordinator` owns restore-plan build/apply tasks, cancellation state,
  live progress snapshots, unresolved-file copying, unresolved-file JSON
  export status, restored-file callbacks, and restore status messages.
- `RestoreUnresolvedExporter` owns unresolved-file export document encoding,
  JSON URL normalization, and default export naming.
- `EncoderViewModel.binding(_:)` provides an explicit SwiftUI binding surface
  for mutable settings; views no longer depend on direct `$model.*` projected
  bindings.
- Characterization coverage was added around encoding, folder sync, media file
  management, versioned decoding, file path transactions, and pure planners.
- View-model persistence characterization coverage now pins encoding settings,
  HEVC/video load order, folder-sync settings, media copy settings, media
  rename settings/history, and selected preset normalization.
- Restore coordinator characterization coverage now pins plan publication,
  apply-result reporting, unresolved-file copy collision handling, and
  unresolved-file JSON export.

## Still remaining

- `EncoderViewModel` is still about 5,500 lines and remains the main
  maintainability risk.
- Settings persistence keys and primitive reads/writes are extracted, but the
  view model still has many `@Published didSet` persistence hooks because state
  still lives on the view-model facade.
- Encoding preflight and file-access authorization still live in the view
  model because they interact with SwiftUI-bound settings and AppKit prompts.
- Folder-sync validation, bookmark authorization, persistence, and collision
  checks still live in the view model.
- Media source/destination panels, job document save/load, prompt construction,
  trash ledger persistence hooks, and compatibility accessors remain in the
  view model.
- Restore-from-backup AppKit folder/save panels still live in the view model.
- `ContentView` remains large, so a full `SettingsStore` extraction is still
  high-risk without widget or UI coverage, even though direct `$model.*`
  bindings have been replaced.

## Assessment

The refactor took the right shape for a large SwiftUI app: it reduced risk by
keeping the public `EncoderViewModel` surface stable while moving actual
execution loops into coordinators. That avoided a broad binding rewrite across
the untested `ContentView`.

The current design is not final. It is a pragmatic facade-plus-coordinators
architecture. The coordinator callbacks are acceptable for now, but they are
also the next coupling point to watch, especially in `MediaFileCoordinator`,
which has a large dependency surface.

## Recommended next implementation slices

1. Keep documentation current.
   Update the plan after each slice so branch status, test count, and remaining
   work stay accurate.

2. Continue shrinking AppKit-facing view-model responsibilities.
   Folder/save panels, security-scoped bookmark authorization, prompt
   construction, and document save/load paths are now the largest coherent
   groups still inside `EncoderViewModel`.

3. Defer full `SettingsStore`.
   The explicit `model.binding(_:)` API gives views a stable binding surface,
   but the underlying settings state still lives on `EncoderViewModel`.
   Introduce a real store only with widget or UI coverage around the current
   bindings.

4. Gradually tighten coordinator dependencies.
   Replace long callback lists with small dependency structs or narrow protocols
   only after the persistence and restore boundaries are stable.

## Verification notes

Headless tests do not fully cover macOS-specific runtime behavior. Manual smoke
testing is still needed for security-scoped bookmarks, FSEvents auto-sync,
AppKit prompts, Trash behavior, and app lifecycle cancellation.
