# GPhilCoder

Native macOS batch audio encoder built with SwiftUI and FFmpeg.

## Current Scope

- Add individual files or whole folders.
- Filter inputs to common audio formats: `.flac`, `.wav`, `.mp3`, `.m4a`, `.aac`, `.aif`, `.aiff`, `.ogg`, `.opus`, and `.wv`.
- Persist selected input filters across launches and queue files.
- Remember the last selected input folder across launches.
- Remember the last selected output format, export route, and encoder settings across launches.
- Save and load explicit `.gphilcoderqueue` files with queued sources and encoder settings.
- Encode audio to MP3 with `libmp3lame`.
- Encode audio to Ogg Vorbis. Bitrate mode uses `libvorbis` when the installed FFmpeg build provides it; otherwise use quality mode with FFmpeg's native `vorbis` encoder.
- Encode audio to Opus with `libopus`.
- Encode audio to lossless FLAC with selectable compression level.
- Encode audio to lossless WavPack.
- Choose format-specific settings: MP3 VBR/CBR/ABR, Ogg quality or bitrate, Opus VBR/CVBR/CBR with bitrates up to 512 kbps, and FLAC compression level.
- Protect same-format encodes by writing `-encoded` output names and blocking exact source overwrites.
- Warn when transcoding lossy sources to lossless FLAC or WavPack output.
- Remove queued items, move individual source files to Trash, or move all queued source files to Trash.
- Restore source files moved to Trash by GPhilCoder when the recorded Trash item still exists.
- Export beside each source file or into a selected export folder.
- Preserve nested folder structure when exporting to a custom folder.
- Process files in parallel while optionally passing a thread count to FFmpeg.

## Requirements

- macOS 14 or newer.
- Xcode command line tools.
- FFmpeg available at one of:
  - bundled in the app at `Contents/Resources/ffmpeg`
  - `/opt/homebrew/bin/ffmpeg`
  - `/usr/local/bin/ffmpeg`
  - `ffmpeg` on `PATH`

Install FFmpeg with Homebrew:

```sh
brew install ffmpeg
```

## Run From Source

```sh
swift run GPhilCoder
```

## Build a Launchable App

```sh
./scripts/build_app.sh
```

The app icon source is `Sources/assets/appicon.png`. The build script regenerates the bundled `.icns` from that file, and `swift run` uses the same PNG for the in-app header.

To bundle a specific FFmpeg binary into the app:

```sh
BUNDLED_FFMPEG=/path/to/ffmpeg ./scripts/build_app.sh
```

Use an FFmpeg build that reports `libvorbis` in `ffmpeg -hide_banner -encoders` to enable full Ogg bitrate controls without depending on the user's installed FFmpeg. For distribution, prefer a self-contained/static FFmpeg build; copying a Homebrew `ffmpeg` binary usually leaves links to Homebrew `.dylib` files on the developer machine.

The build script keeps bundled FFmpeg in the conservative LGPL lane by rejecting binaries whose `ffmpeg -hide_banner -buildconf` output contains `--enable-gpl`, `--enable-nonfree`, or `--enable-version3`. Use `ALLOW_NON_LGPL_FFMPEG=1` only for private experiments, not release builds.

To build a local LGPL-compatible, audio-only FFmpeg candidate with libvorbis:

```sh
./scripts/build_lgpl_ffmpeg.sh
BUNDLED_FFMPEG=vendor/ffmpeg-lgpl/prefix/bin/ffmpeg ./scripts/build_app.sh
```

The helper script builds static libogg, libvorbis, libopus, libmp3lame, and a trimmed audio-only FFmpeg into `vendor/ffmpeg-lgpl/`, then validates that the resulting FFmpeg has no GPL/nonfree/version3 configure flags and no Homebrew runtime library links.

The app bundle is written to:

```text
dist/GPhilCoder.app
```

## Test Common Conversions

```sh
./scripts/test_audio_conversions.sh
```

The script generates short synthetic audio files in common input formats, then verifies conversion to MP3, Ogg, Opus, FLAC, and WavPack with the local FFmpeg build. Same-format re-encodes are skipped so the test focuses on format conversion.

Ogg/Vorbis bitrate values are total stream bitrates, not per-channel bitrates. Quality mode is VBR, so player bitrate readouts vary with source complexity and may be lower than the quality label suggests.

## Plan File Restore From Backup

If source files were copied out of Trash into a temporary folder but their
original paths are unknown, use the restore planner to infer paths from a
structured backup tree. It is non-destructive by default.

```sh
./scripts/plan_restore_from_backup.py \
  --deleted-dir "/path/to/deleted-files" \
  --backup-root "/Volumes/STUDIO_PROJECTS" \
  --restore-root "/Volumes/PROJECTS" \
  --output-dir restore-plan-projects
```

The helper writes:

- `restore_plan.json` with all matches, missing files, and ambiguous files.
- `restore_plan.csv` for spreadsheet review.
- `restore_copy.sh`, a reviewable shell script that copies matched files back
  to the inferred `/Volumes/PROJECTS/...` path without overwriting by default.

By default the generated copy script restores from the deleted-files folder. Use
`--copy-source backup` if you prefer to restore from the backup tree instead.
Run with `--apply` only after reviewing the plan.
