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
