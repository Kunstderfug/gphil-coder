# GPhilCoder tests

## Running

```sh
swift test            # full suite
swift test --filter RestorePlannerTests   # one class
```

## Conventions

- All Core-logic tests use `@testable import GPhilCoderCore`. App-target
  collaborators (e.g. `SecurityScopeManager`) use `@testable import GPhilCoder`.
- Each test class owns its temp directories and removes them in
  `tearDownWithError()` via the shared `makeTemporaryDirectory()` /
  `writeFile(_:in:contents:)` helpers.
- Planner tests exercise the real filesystem (real temp dirs, real
  `FileManager` operations), not mocks. Assertions cover counts, relative
  paths, and applied side effects.
- Decode tests (`VersionedBlobTests`) cover success, corrupt, versionMismatch,
  and legacy bare-array migration for each persisted payload shape.

## Coverage map

| Area | File(s) | Notes |
|------|---------|-------|
| Core planners | `MediaCopyPlannerTests`, `FolderSyncPlannerTests`, `RestorePlannerTests` | Match modes, conflicts, hash disambiguation, apply |
| Encoding presets | `EncodingPresetTests` | CRUD, versioned decode |
| FFmpeg argument building | `FFmpegArgumentsTests` | MP3/Opus/FLAC/WavPack/Ogg args, video args, multichannel split/merge, pan filter, channel-count parsing |
| File-path transactions | `FilePathTransactionsTests` | Collision disambiguation, case-only rename, `-encoded` suffix |
| Versioned-blob decode | `VersionedBlobTests` | Envelope round-trip, corrupt/versionMismatch/legacy paths |
| Security scopes | `SecurityScopeManagerTests` | URL dedup, containment (incl. prefix guard), write probe |

## Known gaps (not covered here, and why)

These paths are **not** unit-tested because they require a real macOS app
environment that the SwiftPM test target cannot provide. They are covered by
manual smoke tests before release (see `scripts/test_audio_conversions.sh` and
`scripts/test_video_conversions.sh` for the conversion paths):

- **`ProcessRunner` cancellation → ffmpeg termination.** Verifying that
  `Task.cancel()` reaches the spawned `ffmpeg` process via SIGTERM requires a
  real `ffmpeg` binary and a long-running encode. The temp-write-then-replace
  discipline in `FFmpegEncoder` is what guarantees no truncated output on cancel;
  the file-path transaction is tested, the process signal is not.

- **Security-scope balance (`startAccessing` / `stopAccessing`).** Real
  security-scoped bookmarks require the sandboxed app context. The pure path
  helpers (`uniqueURLs`, `containsFileURL`, `canWriteTemporaryFile`) **are**
  tested here; the start/stop pairing and stale-bookmark refresh are verified
  manually (authorize a folder-sync pair, rename the watched folder, confirm
  auto-sync still resolves; encode into a scoped export folder; cancel an
  encode and confirm no orphaned scope).

- **`FolderSyncWatcher` FSEvents teardown.** The retained-context fix
  (`passRetained` + `release` callback) closes the use-after-free window during
  `deinit`/`stop()`, but reproducing the race headlessly is not feasible. It is
  verified manually by repeatedly starting/stopping a watcher under load.

## Safe Sync signed-build smoke checklist

Use this checklist once the `History`, `Roll Back`, and `Retry Failures`
controls are present. Test a signed, sandboxed build (not `swift run`) against
disposable folders only. Record the app version, macOS version, volume format,
and pass/fail result. Before starting, verify the bundle and create a fixture:

```sh
codesign --verify --deep --strict --verbose=2 dist/GPhilCoder.app
codesign -d --entitlements :- dist/GPhilCoder.app 2>/dev/null
export SYNC_SMOKE="$(mktemp -d "$HOME/Desktop/GPhilCoder-Safe-Sync.XXXXXX")"
mkdir -p "$SYNC_SMOKE/origin" "$SYNC_SMOKE/destination"
printf 'origin v2\n' > "$SYNC_SMOKE/origin/overwrite.txt"
printf 'new item\n' > "$SYNC_SMOKE/origin/new.txt"
printf 'destination v1\n' > "$SYNC_SMOKE/destination/overwrite.txt"
printf 'destination only\n' > "$SYNC_SMOKE/destination/delete.txt"
```

The displayed entitlements must include
`com.apple.security.app-sandbox = true`.

### Defaults, destructive review, and macOS Trash

- [ ] With a fresh app container or test account, add the fixture as a Sync
  pair. Confirm **Sync deletions** is off by default. Turn it on, cancel its
  warning, and confirm it stays off; accept the warning and confirm it turns on.
- [ ] Scan the pair. Confirm the preview identifies the new copy, overwrite,
  and deletion, and that its visible rows and totals describe the same plan.
- [ ] Choose **Apply Reviewed Plan**, then cancel the destructive confirmation.
  Confirm all fixture contents are byte-for-byte unchanged and no run claims
  success in **History**.
- [ ] Apply the same reviewed plan and confirm it. Confirm `new.txt` is copied,
  `overwrite.txt` contains `origin v2`, and `delete.txt` is absent. Open the
  actual macOS Trash in Finder and confirm the retained destination items are
  there; **History** must identify Trash as the recovery mechanism.

### Bookmarks, FSEvents, and whole-batch pause

- [ ] With deletion off and auto-sync on, add `automatic-copy.txt` to the
  origin while the signed app is open. Confirm the FSEvents-triggered run copies
  it without a manual scan and records an automatic, copy-only run.
- [ ] Quit fully, relaunch the signed app, and add another origin file. Confirm
  the persisted security-scoped bookmarks restore access without an authorize
  loop and auto-sync copies the file.
- [ ] Turn deletion on, place `automatic-delete.txt` only in the destination and
  `automatic-new.txt` only in the origin, then trigger FSEvents. Confirm the app
  shows **REVIEW REQUIRED** and pauses the whole batch: neither the copy nor the
  deletion may run before review. Cancelling review leaves both unchanged.

### Same-volume quarantine fallback

- [ ] On a disposable volume where Trash is unavailable, repeat a destructive
  Sync. One reproducible fixture is a fresh APFS sparse image whose `.Trashes`
  path is deliberately occupied by a file:

  ```sh
  hdiutil create -size 128m -fs APFS -volname GPhilSyncFallback \
    -type SPARSE "$SYNC_SMOKE/GPhilSyncFallback"
  hdiutil attach "$SYNC_SMOKE/GPhilSyncFallback.sparseimage"
  export SYNC_FALLBACK=/Volumes/GPhilSyncFallback
  : > "$SYNC_FALLBACK/.Trashes"
  mkdir -p "$SYNC_FALLBACK/origin" "$SYNC_FALLBACK/destination"
  printf 'source replacement\n' > "$SYNC_FALLBACK/origin/replace.txt"
  printf 'prior destination\n' > "$SYNC_FALLBACK/destination/replace.txt"
  printf 'destination only\n' > "$SYNC_FALLBACK/destination/delete.txt"
  ```

  Confirm Sync succeeds, **History** reports same-volume quarantine rather than
  Trash, and retained files exist below
  `$SYNC_FALLBACK/.gphilcoder-sync-quarantine`. Compare `stat -f %d` for the
  destination and quarantine paths to confirm they are on the same volume. If
  the items reached Trash instead, the fixture did not exercise this case.

### Cancellation, relaunch, rollback, and conflicts

- [ ] Use a fixture large enough to leave **Cancel** enabled. Cancel during
  apply and confirm no new operations start afterward. **History** totals must
  match the on-disk successful/cancelled outcomes, retained items must remain
  recoverable, and no `.gphilcoder-sync-*.tmp` file may remain.
- [ ] Repeat, but quit during apply. Relaunch and confirm the recovered history,
  journal, destination contents, and available recovery actions describe the
  completed/incomplete boundary consistently, by the same rules as an explicit
  cancellation.
- [ ] Relaunch after a completed destructive run, select it in **History**, and
  choose **Roll Back**. Confirm deleted and overwritten destination versions are
  restored, newly created copies are removed, every rollback outcome is shown,
  and an emptied quarantine tree is cleaned up. Repeat this for one Trash-backed
  run and one quarantine-backed run.
- [ ] Complete another overwrite, then modify its applied destination before
  **Roll Back**. Confirm recovery does not overwrite the newer file, reports a
  conflict, and retains the prior version. Move the conflicting file aside,
  choose **Retry Failures**, and confirm only the unresolved recovery is retried.

### Keyboard and accessibility

- [ ] Enable macOS Full Keyboard Access and complete the Sync safety flow without
  a pointer. Verify logical focus order and visible focus for **Sync deletions**,
  the safety warning, **Scan**, preview rows, **Apply Reviewed Plan**, destructive
  confirmation, **History**, **Roll Back**, and **Retry Failures**. Escape must
  cancel a destructive dialog without mutation.
- [ ] With VoiceOver, verify labels, values, and state changes are announced for
  deletion on/off, **REVIEW REQUIRED**, plan counts, destructive scope, progress,
  cancellation, completion, recovery mechanism, and recovery conflicts.
