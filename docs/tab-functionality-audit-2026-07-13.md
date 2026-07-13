# GPhilCoder Tab Functionality Audit

**Audit date:** 2026-07-13
**Audited revision:** `main` at `793f6b0` (`Refactor ContentView into workflow views`)
**Scope:** Audio, Video, Copy, Rename, Delete, Sync, Restore, and shared app-shell behavior

## Purpose

This document is a decision backlog, not an implementation commitment. It separates:

- **Confirmed gaps:** behavior that is incomplete, inconsistent, unsafe, or misleading based on the current UI and source.
- **Development opportunities:** useful completions of an existing workflow.
- **Optional product ideas:** plausible additions that should be implemented only if real user workflows justify them.

## Audit method and limits

The current checkout was built with `./scripts/build_app.sh`. A fresh local audit bundle was used to capture the default state of all seven tabs. The source, README, and current test suite were then inspected to trace what each control actually does. `swift test` passes all 156 tests.

No real user files were encoded, copied, renamed, deleted, synchronized, or restored during this review. File pickers, notification prompts, non-empty lists, and destructive confirmations were therefore assessed from current source and tests rather than exercised against user data.

The app's accessibility snapshot service failed while reading this SwiftUI window. The screenshots were still captured and inspected, but keyboard focus order, VoiceOver announcements, target sizes, and measured contrast remain verification gaps. This document does not claim accessibility compliance.

Local screenshots from this audit are stored outside the repository at:

`/Users/slav/.codex/visualizations/2026/07/13/019f5a59-3cb6-7611-b7da-1af24e66cb22/gphilcoder-tab-audit/`

## Executive assessment

GPhilCoder is already much deeper than a simple transcoder. Audio is the most complete workflow; Video is capable locally but has a distribution mismatch; Copy and Sync have correctness issues that should be resolved before adding features; Rename and Delete need selective review/recovery controls; Restore has a sophisticated planner but an underdeveloped apply phase.

The default screens are generally clear. Each tab has a useful empty state, the primary action is visible, and color consistently identifies the current workflow. The highest-risk problems are below the presentation layer:

1. Sync combines automatic runs with destination deletion, and deletions are permanent.
2. Copy accepts multiple source folders, but immediate Scan/Copy uses only the first source.
3. Sync totals cover all enabled pairs while its visible operation preview shows only the first pair.
4. Restore overwrite removes an existing target before the replacement copy succeeds.
5. The Video tab remains visible in App Store builds even though that build cannot obtain the system FFmpeg required to run it.

## Decision shortlist

| Priority | Decision | Recommended direction |
| --- | --- | --- |
| P0 | Sync deletion safety | Default deletion off; confirm destructive plans; move deletes to Trash/quarantine or journal them for rollback. |
| P0 | Copy multi-source semantics | Make Scan, Copy now, and queued Copy operate on the same source set and explicit destination-layout rule. |
| P0 | Sync multi-pair preview | Group and label operations for every enabled pair; totals and visible rows must describe the same plan. |
| P0 | Restore overwrite safety | Copy to a temporary sibling first, then atomically replace the target only after the copy succeeds. |
| P1 | Video distribution truth | Either bundle VideoToolbox-capable FFmpeg for App Store builds or present Video as unavailable with a precise explanation. |
| P1 | Selective review and recovery | Add reusable per-item include/exclude, conflict resolution, result history, and retry patterns across file workflows. |
| P1 | Restore execution control | Add selectable matches, ambiguous-candidate resolution, determinate progress, and cancel during apply. |
| P1 | App-shell context and keyboard use | Persist the selected tab, remove stale Video status from non-encoding workflows, and add tab/context shortcuts. |
| P2 | Broader media capabilities | Decide from concrete workflows before adding codecs, metadata, loudness, scheduling, regex, or checksum features. |

---

## 1. Audio

**Current maturity: Strong.** The core batch-encoding workflow is well developed.

### Already developed

- Files, folders, and drag-and-drop input.
- Format filters and persistent queue documents.
- MP3, Ogg, Opus, FLAC, and WavPack settings.
- Export beside sources or into a selected export folder while preserving nested structure.
- Preset CRUD, parallel jobs, FFmpeg thread control, overwrite protection, multichannel splitting, progress, ETA, cancellation, error-log copy, Trash, and Trash restore.
- Clear empty state and a pinned Start action in the settings rail.

### Confirmed gaps

1. **Cancelled jobs are not a first-class result.** `JobState.cancelled` exists, but the summary/filter strip has no Cancelled count or filter. Cancelled jobs remain mixed into the unfiltered list. Evidence: [Models.swift](../Sources/GPhilCoder/Models.swift#L188), [EncodingCoordinator.swift](../Sources/GPhilCoder/EncodingCoordinator.swift#L100), [EncodingRows.swift](../Sources/GPhilCoder/Views/EncodingRows.swift#L100).

2. **There is no retry workflow.** Completed rows only expose Reveal, and failed rows expose Copy Error Log. There is no Retry failed, Retry selected, Remove result, or Clear finished action. Evidence: [EncodingRows.swift](../Sources/GPhilCoder/Views/EncodingRows.swift#L418).

3. **Queue repair is weak.** Missing sources are skipped during queue load with a summary message; there is no Locate missing file/folder flow. The queue document declares a version, but load does not validate or migrate it. Evidence: [Models.swift](../Sources/GPhilCoder/Models.swift#L309), [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift#L3315).

4. **Ogg silently forces stereo.** The encoder arguments add `-ac 2`; the Audio UI has no channel-layout choice or warning for multichannel input. Evidence: [FFmpegArguments.swift](../Sources/GPhilCoderCore/FFmpegArguments.swift#L209).

5. **Presets are narrower than the full job.** Codec settings are saved, while routing, overwrite behavior, concurrency, and other job-level choices live outside the preset. That may be correct, but the current label “Preset” does not explain the boundary. Evidence: [EncodingModels.swift](../Sources/GPhilCoderCore/EncodingModels.swift#L648), [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift#L3831).

### Development opportunities

- Retry failed/selected jobs and clear completed results.
- Relink missing queue sources instead of dropping them.
- Import/export encoding presets.
- Explicit output naming suffix/template control.
- Make channel conversion visible and intentional.

### Optional ideas requiring user demand

- WAV/AIFF output, sample-rate and bit-depth conversion, dithering.
- Loudness normalization, metadata/artwork handling, and silence trimming.

These are not current defects; the existing app is intentionally focused on compressed and lossless delivery formats.

---

## 2. Video

**Current maturity: Capable locally, incomplete as a distributable feature.**

### Already developed

- MP4/MOV/M4V input and MP4/MOV output.
- HEVC VideoToolbox presets, custom bitrate, source/1080p/4K caps, Main10, audio copy/AAC, hardware-decode controls, progress, throughput, and pipeline badges.
- Shared queue, preset, routing, confirmation, cancellation, and error states with Audio.

### Confirmed gaps

1. **Video cannot run in the App Store build.** App Store builds disable system FFmpeg, Video always selects system FFmpeg, and the tab is unconditional. The bundled FFmpeg is currently audio-focused. Evidence: [README.md](../README.md#L105), [README.md](../README.md#L116), [FFmpegTool.swift](../Sources/GPhilCoder/FFmpegTool.swift#L48), [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift#L1744), [SharedShellComponents.swift](../Sources/GPhilCoder/Views/SharedShellComponents.swift#L5).

2. **“Auto” and “Prefer” hardware decode are not meaningfully different.** Both enable VideoToolbox arguments, and the encode path disables software fallback. Either implement a real Auto fallback or simplify/rename the choices. Evidence: [EncodingModels.swift](../Sources/GPhilCoderCore/EncodingModels.swift#L303), [FFmpegTool.swift](../Sources/GPhilCoder/FFmpegTool.swift#L240), [FFmpegArguments.swift](../Sources/GPhilCoderCore/FFmpegArguments.swift#L322).

3. **The scope is HEVC-only.** This is a valid product boundary, but it should be explicit because the top-level label says Video rather than HEVC. Evidence: [EncodingModels.swift](../Sources/GPhilCoderCore/EncodingModels.swift#L119).

4. **The app-level Video path lacks coordinator coverage.** The FFmpeg smoke script and argument tests cover conversion mechanics, but not the app's Video queue, settings snapshot, output naming, cancellation, and result-state integration.

### Development opportunities

- Resolve App Store availability before broadening codecs.
- First-run capability guidance when system FFmpeg or `hevc_videotoolbox` is unavailable.
- Make hardware fallback behavior match the control labels.
- Add app-level Video coordinator tests.

### Optional ideas requiring user demand

- H.264 for compatibility, ProRes for mastering, or AV1 for distribution.
- Frame-rate conversion, crop/aspect controls, subtitle handling, and audio-track selection.

---

## 3. Copy

**Current maturity: Broad workflow with two correctness inconsistencies.**

### Already developed

- Multiple source-folder selection, destination selection, audio/video/custom-extension and filename filters.
- Preview counts and conflict handling.
- Copy now and persistent queued workflows with Plan/Queue views.
- Progress, throughput, cancellation, and restore records.

### Confirmed gaps

1. **Immediate Scan/Copy processes only the first selected source folder.** The UI and model accept multiple roots, but `primaryMediaCopySourceRoot` is used for the immediate path. Add to queue expands all roots. Evidence: [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift#L1534), [MediaFileCoordinator+State.swift](../Sources/GPhilCoder/MediaFileCoordinator+State.swift#L18), [MediaFileCoordinator.swift](../Sources/GPhilCoder/MediaFileCoordinator.swift#L149), [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift#L2795).

2. **Copy now and queued Copy use different destination layouts.** Immediate Copy places source contents directly into the destination; queued Copy wraps each workflow in the source-folder name. Users can receive a different tree based only on which Start path they choose. Evidence: [MediaFileCoordinator.swift](../Sources/GPhilCoder/MediaFileCoordinator.swift#L436), [MediaCopyPlanner.swift](../Sources/GPhilCoderCore/MediaCopyPlanner.swift#L472).

3. **The queue is not editable.** Rows can be removed but not reordered, edited, duplicated, disabled, or paused. Evidence: [MediaManagementRows.swift](../Sources/GPhilCoder/Views/MediaManagementRows.swift#L230).

4. **The preview is all-or-nothing.** Users cannot exclude individual items, and per-file failures collapse into a short global message with no durable result list or Retry failed action. Evidence: [MediaManagementRows.swift](../Sources/GPhilCoder/Views/MediaManagementRows.swift#L5), [MediaFileCoordinator.swift](../Sources/GPhilCoder/MediaFileCoordinator.swift#L754).

5. **Package handling is unclear.** Package descendants are skipped during inventory, which can produce directory-shell behavior rather than copying a package atomically. Evidence: [MediaCopyPlanner.swift](../Sources/GPhilCoderCore/MediaCopyPlanner.swift#L638).

### Recommended completion

- Make all source roots and destination layout explicit and identical in Scan, Copy now, and Queue.
- Add per-item inclusion and a retained result list before adding more copy modes.
- Decide whether packages should be atomic files, ordinary folders, or explicitly unsupported.

### Optional ideas requiring user demand

- Keep-both conflict handling, checksum verification, reusable Copy presets, and queue priority.

---

## 4. Rename

**Current maturity: Strong planner, weak exception handling.**

### Already developed

- Pattern, Auto Index, Replace, Add Text, Case, and Clean operations.
- Type/extension/name filters, sorting, validation, stale-preview protection, progress, and up to 20 persisted undo/redo transactions.
- Safe handling for case-only changes and duplicate targets.

### Confirmed gaps

1. **One blocked item blocks the entire batch.** Ready items cannot proceed when any conflict exists. Rows have no Exclude, Skip, or manual target edit. Evidence: [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift#L1340), [MediaFileCoordinator+ManagedOperations.swift](../Sources/GPhilCoder/MediaFileCoordinator+ManagedOperations.swift#L119), [MediaManagementRows.swift](../Sources/GPhilCoder/Views/MediaManagementRows.swift#L69).

2. **Undo/redo is discoverable only in the tab.** The backend retains history, but standard Command-Z and Shift-Command-Z are not connected to Rename. Evidence: [GPhilCoderApp.swift](../Sources/GPhilCoder/GPhilCoderApp.swift#L44), [MediaManagementWorkflowView.swift](../Sources/GPhilCoder/Views/MediaManagementWorkflowView.swift#L663).

3. **Clean is under-explained.** Its settings area is empty and the UI does not explain that it replaces underscores/hyphens and collapses whitespace. Evidence: [MediaRenameSettingsWindow.swift](../Sources/GPhilCoder/MediaRenameSettingsWindow.swift#L146), [MediaRenamePlanner.swift](../Sources/GPhilCoderCore/MediaRenamePlanner.swift#L612).

### Development opportunities

- Per-row include/exclude and manual target overrides.
- “Rename ready items and skip blocked” as an explicit option.
- Standard undo/redo shortcuts and a small history browser rather than only the last action.
- Saved rename recipes if users repeat the same rules.

### Optional ideas requiring user demand

- Regex replace, metadata-derived tokens, extension renaming, and cycle/swap resolution.

---

## 5. Delete

**Current maturity: Clear destructive flow, incomplete review and recovery.**

### Already developed

- Multiple roots, audio/video/extension/name filters, preview, confirmation, progress, and cancellation.
- Files move to macOS Trash rather than being permanently removed.
- Emergency journal and restore ledger provide a real safety net.
- Red workflow identity and action styling clearly communicate risk.

### Confirmed gaps

1. **No per-item exclusion.** The preview is display-only, so a false positive requires changing the global filter rather than unchecking one file. Evidence: [MediaManagementRows.swift](../Sources/GPhilCoder/Views/MediaManagementRows.swift#L172).

2. **Trash restore is bulk and opaque.** Restore attempts every saved record. There is no ledger browser, per-record restore, record inspection, or destination-conflict decision. Evidence: [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift#L2362), [MediaManagementWorkflowView.swift](../Sources/GPhilCoder/Views/MediaManagementWorkflowView.swift#L687).

3. **Failures are not retained.** The result message includes only a few filenames; there is no inspectable operation result or retry path. Evidence: [MediaFileCoordinator+ManagedOperations.swift](../Sources/GPhilCoder/MediaFileCoordinator+ManagedOperations.swift#L655).

### Recommended completion

- Selective deletion with a final selected-count/size summary.
- A dedicated Trash ledger with per-record Restore, Reveal, Remove record, and conflict handling.
- Persistent results shared with Copy and Rename.

### Optional ideas requiring user demand

- Date, size, and age filters; saved cleanup recipes.

---

## 6. Sync

**Current maturity: Feature-rich but not yet safe enough for unattended use.**

### Already developed

- Multiple folder pairs, enabled/disabled states, pair-list save/load, two destination layouts, security-scoped bookmark persistence, and FSEvents watching.
- All/audio/video/custom-extension filters, Scan, Sync, overwrite and deletion controls, aggregate counts, progress, throughput, and cancellation.
- The empty state explains pair creation clearly.

### Confirmed gaps

1. **Unsafe defaults combine.** Fresh settings enable Overwrite destination files, Sync deletions, and Auto-sync while app is open. The screenshot makes all three active at once.

2. **Sync deletion is permanent.** Destination extras are removed with `FileManager.removeItem`, not Trash, quarantine, or a rollback journal. Manual Sync has no deletion confirmation, and the watcher can run the same plan automatically. Evidence: [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift#L236), [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift#L274), [FolderSyncPlanner.swift](../Sources/GPhilCoderCore/FolderSyncPlanner.swift#L260), [FolderSyncWorkflowView.swift](../Sources/GPhilCoder/Views/FolderSyncWorkflowView.swift#L244), [FolderSyncCoordinator.swift](../Sources/GPhilCoder/FolderSyncCoordinator.swift#L440).

3. **The visible preview is incomplete for multiple pairs.** Totals aggregate every enabled pair, but the preview is captured only while `previewPlan` is nil, so its rows represent the first pair only. The preview is not labeled as partial. Evidence: [FolderSyncCoordinator.swift](../Sources/GPhilCoder/FolderSyncCoordinator.swift#L210), [FolderSyncWorkflowView.swift](../Sources/GPhilCoder/Views/FolderSyncWorkflowView.swift#L350).

4. **Change detection uses size and modification time, not content.** This is fast, but it needs to be an explicit product tradeoff if Sync is trusted for important media. Evidence: [FolderSyncPlanner.swift](../Sources/GPhilCoderCore/FolderSyncPlanner.swift#L361).

5. **Filtering is extension-only.** There are no ignore patterns for caches, hidden folders, temporary files, or per-operation opt-out. Evidence: [FolderSyncWorkflowView.swift](../Sources/GPhilCoder/Views/FolderSyncWorkflowView.swift#L142).

6. **There is no run history.** Auto-sync works only while the app is open and provides no durable audit of what changed, failed, or was deleted.

### Recommended completion

- Default deletions off.
- Grouped preview for every pair, with pair name/path on each operation.
- Explicit confirmation when a plan contains deletions, including count and total size.
- Trash/quarantine or versioned staging, plus a retained transaction log and rollback path.
- Ignore rules and a configurable destructive-change threshold before unattended runs.

### Optional ideas requiring user demand

- Content hashes, schedules, launch-at-login/background agent, per-pair profiles, and bidirectional sync.

Bidirectional sync should not be assumed; it is a separate conflict model, not a small extension of mirroring.

---

## 7. Restore

**Current maturity: Sophisticated planning, underdeveloped resolution and apply phase.**

### Already developed

- Deleted/backup/restore roots and a clear non-destructive planning model.
- Filename + size or filename-only matching, Auto/Always/Never hashing, copy-source choice, hidden-file and overwrite controls.
- Cancellable plan search with partial counters, live status categories, unresolved JSON export, holding-folder copy, and matched-file restore.
- A reassuring footer explicitly states that planning/copying does not delete from the deleted folder or backup.

### Confirmed gaps

1. **Apply cannot be cancelled.** Search has Stop, but restore application has no cancellation route. The app also blocks quitting during restore, leaving the user to wait. Evidence: [RestoreFromBackupSheet.swift](../Sources/GPhilCoder/RestoreFromBackupSheet.swift#L144), [RestoreCoordinator.swift](../Sources/GPhilCoder/RestoreCoordinator.swift#L101), [GPhilCoderApp.swift](../Sources/GPhilCoder/GPhilCoderApp.swift#L228).

2. **Apply progress is indeterminate.** It shows no current file, completed count, remaining count, or byte progress. Evidence: [RestoreFromBackupSheet.swift](../Sources/GPhilCoder/RestoreFromBackupSheet.swift#L264), [RestoreCoordinator.swift](../Sources/GPhilCoder/RestoreCoordinator.swift#L101).

3. **Ambiguous matches cannot be resolved.** The planner retains candidates, but the UI shows only the count and first path. There is no candidate chooser to turn an ambiguous record into a restore decision. Evidence: [RestoreFromBackupSheet.swift](../Sources/GPhilCoder/RestoreFromBackupSheet.swift#L675), [RestorePlanner.swift](../Sources/GPhilCoderCore/RestorePlanner.swift#L218).

4. **Restore is all matched files or none.** Summary categories are informational rather than filters, rows are not selectable, and Apply processes every matched/matched-conflict record. Evidence: [RestoreFromBackupSheet.swift](../Sources/GPhilCoder/RestoreFromBackupSheet.swift#L183), [RestorePlanner.swift](../Sources/GPhilCoderCore/RestorePlanner.swift#L630).

5. **Overwrite is not atomic.** The existing target is removed before the new copy is attempted. A copy failure after removal can lose the previous target. Evidence: [RestorePlanner.swift](../Sources/GPhilCoderCore/RestorePlanner.swift#L648).

6. **Long plans cannot be resumed.** Only unresolved items can be exported; there is no full plan document that can be saved, reviewed, reopened, and applied later.

### Recommended completion

- Per-record selection and category filters.
- Candidate chooser for ambiguous results and per-record overwrite/skip decisions.
- Determinate, cancellable apply progress.
- Temporary sibling copy plus atomic replacement.
- Versioned full-plan save/load for long searches.

---

## Cross-cutting findings

### 1. A shared activity/results center would improve every workflow

The footer is one truncated status line. Copy, Rename, Delete, Sync, and Restore often compress failures to a few names or a count. A retained activity center could own:

- running and recent operations;
- per-item success, skipped, failed, and cancelled states;
- retry selected/failed;
- reveal/copy-log/export-report actions;
- operation history and recovery links.

This should be a shared state/UI module with workflow-specific result payloads, not duplicated ad hoc in each tab. Evidence: [SharedShellComponents.swift](../Sources/GPhilCoder/Views/SharedShellComponents.swift#L141).

### 2. Encoding status leaks into non-encoding tabs

After visiting Video, Copy/Rename/Delete/Sync/Restore continue to show System FFmpeg and Video pipeline badges. `syncWorkflowSelection` intentionally leaves `encodingWorkflow` unchanged for non-encoding tabs, and the footer keys only off that model value. This status is unrelated to the active task and can conflict visually with the Bundled selector. Evidence: [ContentView.swift](../Sources/GPhilCoder/ContentView.swift#L84), [SharedShellComponents.swift](../Sources/GPhilCoder/Views/SharedShellComponents.swift#L141).

Recommended direction: hide encoder-specific status outside Audio/Video or label it as the last encoding configuration.

### 3. The selected tab is not restored

`ContentView` always starts on Audio and then overwrites the persisted encoding workflow on appearance. This is inconsistent with the model's persisted Video workflow. Evidence: [ContentView.swift](../Sources/GPhilCoder/ContentView.swift#L7), [ContentView.swift](../Sources/GPhilCoder/ContentView.swift#L31).

### 4. Keyboard commands are encoding-centric

The Workflow menu exposes Add, Start Encoding, Cancel, Refresh Preview, and queue actions, but not tab selection or context-specific primary actions. Rename undo/redo is not connected to standard shortcuts. Evidence: [GPhilCoderApp.swift](../Sources/GPhilCoder/GPhilCoderApp.swift#L44).

Recommended direction:

- Command-1 through Command-7 for tabs.
- One context-aware primary-action command.
- Standard Undo/Redo while Rename is active.
- Keyboard focus and VoiceOver verification for every custom tab/control.

### 5. Compact layouts are unsupported

The main window enforces a 1320 × 940 minimum. The current seven-tab bar and three-column layouts are readable at that size, but there is no compact-window or reflow path. Evidence: [GPhilCoderApp.swift](../Sources/GPhilCoder/GPhilCoderApp.swift#L4).

This is both a small-screen usability and accessibility-zoom risk. Verify real target Macs before deciding whether to redesign.

### 6. Onboarding and end-user help are thin

The README is primarily a developer/build document and only partially explains the dedicated file-management workflows. Useful in-app help would cover:

- bundled vs system FFmpeg and Video availability;
- queue/preset/job document boundaries;
- Copy-now vs Queue semantics;
- Delete Trash recovery vs permanent Sync deletion;
- Restore planning and match modes;
- notification setup.

### 7. Saved-document versioning is inconsistent

Encoding and Copy job documents include versions, but load paths do not validate future versions. Sync pair lists are a bare array rather than a versioned document. Before formats grow, add rejection/migration behavior and guided repair for missing folders.

### 8. UI/accessibility coverage is missing

The planner/coordinator suite is substantial, but there are no SwiftUI/UI or accessibility tests. Manual checks are still needed for file pickers, bookmarks, FSEvents, Trash, prompts, notifications, lifecycle, full keyboard access, VoiceOver, and high display scaling.

### 9. Feature work should not expand the monolithic view model

The extracted workflow views are now focused and remain under the 1,000-line source-file limit, but [EncoderViewModel.swift](../Sources/GPhilCoder/EncoderViewModel.swift) is roughly 5,500 lines. Future feature packages should extract the owning state/service boundary while they are implemented:

- Sync safety/history into Sync-specific state and services.
- Restore application control into Restore-specific state and services.
- Shared operation results into a narrow cross-workflow module.
- Document migration/repair into persistence modules.

Avoid a broad rewrite; refactor the seam owned by each approved feature.

## Suggested implementation packages

These packages are intentionally separable so decisions can be made independently.

### Package A — Safe Sync

- Deletions default off.
- Complete grouped preview across pairs.
- Destructive-plan confirmation and threshold.
- Trash/quarantine/journal and rollback.
- Retained run history.

### Package B — Copy correctness

- All source roots in every path.
- One explicit destination-layout model.
- Repairable/versioned queue documents.
- Tests proving immediate and queued parity.

### Package C — Restore control and safety

- Candidate resolution and row selection.
- Determinate/cancellable apply.
- Atomic overwrite.
- Versioned save/load plan.

### Package D — Shared review and results

- Reusable selectable preview rows.
- Per-item outcomes and retained operation history.
- Retry/reveal/log/export actions.
- Adopt first in Copy/Delete/Rename, then Sync/Restore where appropriate.

### Package E — Distribution capability truth

- Runtime/build capability model.
- App Store Video unavailable state or bundled VideoToolbox FFmpeg.
- First-run guidance and app-level Video tests.

### Package F — Productivity and shell clarity

- Tab persistence and shortcuts.
- Context-aware status/footer.
- Standard Rename undo/redo.
- Compact-layout and accessibility verification.

## Recommended decision order

1. Decide the Sync deletion/rollback contract.
2. Fix Copy multi-source and destination-layout parity.
3. Make Sync preview represent all pairs.
4. Make Restore overwrite atomic.
5. Decide whether App Store Video is supported, unavailable, or removed.
6. Choose whether selective review/results should become a shared pattern.
7. Complete Restore resolution and apply controls.
8. Address tab/status/keyboard usability.
9. Only then choose optional codec and workflow expansion from observed user needs.

## Documentation maintenance found during the audit

- Current tests: 156 passing.
- [refactoring-plan.md](refactoring-plan.md) still cites 146 tests and describes RestoreCoordinator as future work.
- [refactoring-implementation-summary.md](refactoring-implementation-summary.md) cites 150 tests and describes `ContentView` as large even though it has already been split.
- [TESTING.md](../Tests/GPhilCoderTests/TESTING.md) does not list several current coordinator, persistence, restore, and sync-pair suites.

Before using those documents for future planning, mark the old plan as archival and refresh the current architecture/test map.

## Decision worksheet

- [ ] Approve Safe Sync package.
- [ ] Approve Copy correctness package.
- [ ] Approve Restore atomic overwrite only.
- [ ] Approve complete Restore control/safety package.
- [ ] Decide App Store Video direction.
- [ ] Approve shared review/results design.
- [ ] Approve productivity/shell cleanup.
- [ ] Select any optional Audio additions.
- [ ] Select any optional Video additions.
- [ ] Select any optional Rename/Copy/Delete/Sync additions.
