# GPhil Codec

Native macOS batch audio encoder built with SwiftUI and FFmpeg.

## Current Scope

- Add individual files or whole folders.
- Filter inputs to `.flac`, `.wav`, and `.mp3`.
- Persist selected input filters across launches and queue files.
- Remember the last selected input folder across launches.
- Remember the last selected output format, export route, and encoder settings across launches.
- Save and load explicit `.gphilcodecqueue` files with queued sources and encoder settings.
- Encode audio to MP3 with `libmp3lame`.
- Encode audio to Ogg Vorbis. Bitrate mode uses `libvorbis` when the installed FFmpeg build provides it; otherwise use quality mode with FFmpeg's native `vorbis` encoder.
- Encode audio to Opus with `libopus`.
- Choose format-specific settings: MP3 VBR/CBR/ABR, Ogg quality or bitrate, and Opus VBR/CVBR/CBR with bitrates up to 512 kbps.
- Protect same-format encodes by writing `-encoded` output names and blocking exact source overwrites.
- Export beside each source file or into a selected export folder.
- Preserve nested folder structure when exporting to a custom folder.
- Process files in parallel while optionally passing a thread count to FFmpeg.

## Requirements

- macOS 14 or newer.
- Xcode command line tools.
- FFmpeg available at one of:
  - `/opt/homebrew/bin/ffmpeg`
  - `/usr/local/bin/ffmpeg`
  - `ffmpeg` on `PATH`

Install FFmpeg with Homebrew:

```sh
brew install ffmpeg
```

## Run From Source

```sh
swift run GPhilCodec
```

## Build a Launchable App

```sh
./scripts/build_app.sh
```

The app bundle is written to:

```text
dist/GPhilCodec.app
```
