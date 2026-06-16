#!/usr/bin/env bash
set -euo pipefail

FFMPEG="${FFMPEG:-}"
if [[ -z "$FFMPEG" ]]; then
  for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg ffmpeg; do
    if command -v "$candidate" >/dev/null 2>&1; then
      FFMPEG="$(command -v "$candidate")"
      break
    elif [[ -x "$candidate" ]]; then
      FFMPEG="$candidate"
      break
    fi
  done
fi

if [[ -z "$FFMPEG" ]]; then
  echo "FFmpeg was not found. Install it or set FFMPEG=/path/to/ffmpeg." >&2
  exit 1
fi

FFPROBE="${FFPROBE:-$(dirname "$FFMPEG")/ffprobe}"
if [[ ! -x "$FFPROBE" ]]; then
  FFPROBE="$(command -v ffprobe || true)"
fi

if [[ -z "$FFPROBE" ]]; then
  echo "ffprobe was not found next to FFmpeg or on PATH." >&2
  exit 1
fi

ENCODERS="$("$FFMPEG" -hide_banner -encoders 2>/dev/null || true)"
if [[ "$ENCODERS" != *"hevc_videotoolbox"* ]]; then
  echo "FFmpeg does not include hevc_videotoolbox; video conversion cannot use Apple Silicon HEVC." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d /tmp/gphilcoder-video-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

GENERATOR_FFMPEG="${GENERATOR_FFMPEG:-$FFMPEG}"
GENERATOR_ENCODERS="$("$GENERATOR_FFMPEG" -hide_banner -encoders 2>/dev/null || true)"

generator_video_args=()
if [[ "$GENERATOR_ENCODERS" == *"h264_videotoolbox"* ]]; then
  generator_video_args=(-c:v h264_videotoolbox -b:v 2000k -tag:v avc1)
elif [[ "$GENERATOR_ENCODERS" == *" mpeg4 "* ]]; then
  generator_video_args=(-c:v mpeg4 -q:v 5)
else
  echo "Generator FFmpeg cannot create a compact MP4/MOV fixture. Set GENERATOR_FFMPEG to a fuller FFmpeg." >&2
  exit 1
fi

make_input() {
  local extension="$1"
  local output="$WORK_DIR/input.$extension"

  "$GENERATOR_FFMPEG" -hide_banner -nostdin -y \
    -f lavfi -i testsrc2=size=1280x720:rate=24:duration=1 \
    -f lavfi -i sine=frequency=440:duration=1 \
    "${generator_video_args[@]}" \
    -c:a aac -b:a 128k -shortest "$output" \
    >/dev/null 2>"$WORK_DIR/create-$extension.log"

  echo "$output"
}

make_large_input() {
  local output="$WORK_DIR/input-4k.mp4"

  "$GENERATOR_FFMPEG" -hide_banner -nostdin -y \
    -f lavfi -i testsrc2=size=3840x2160:rate=24:duration=1 \
    -f lavfi -i sine=frequency=550:duration=1 \
    "${generator_video_args[@]}" \
    -c:a aac -b:a 128k -shortest "$output" \
    >/dev/null 2>"$WORK_DIR/create-4k.log"

  echo "$output"
}

probe_field() {
  local file="$1"
  local field="$2"
  "$FFPROBE" -hide_banner -v error \
    -select_streams v:0 \
    -show_entries "stream=$field" \
    -of default=noprint_wrappers=1:nokey=1 "$file" | head -n 1
}

probe_dimensions() {
  local file="$1"
  "$FFPROBE" -hide_banner -v error \
    -select_streams v:0 \
    -show_entries stream=width,height \
    -of csv=s=x:p=0 "$file" | head -n 1
}

run_conversion() {
  local input="$1"
  local output="$2"
  shift 2

  "$FFMPEG" -hide_banner -nostdin -y \
    -hwaccel videotoolbox \
    -i "$input" \
    -map 0:v:0 -map 0:a? \
    -c:v hevc_videotoolbox \
    "$@" \
    -tag:v hvc1 \
    -allow_sw 0 \
    -prio_speed 1 \
    -realtime 1 \
    -power_efficient 0 \
    -c:a copy "$output" \
    >/dev/null 2>"$WORK_DIR/$(basename "$output").log"
}

failures=0
inputs=()

echo "Using FFmpeg: $FFMPEG"
echo "Using generator FFmpeg: $GENERATOR_FFMPEG"
echo "Using ffprobe: $FFPROBE"
echo "Work dir: $WORK_DIR"
echo

for extension in mp4 mov; do
  if input="$(make_input "$extension")"; then
    inputs+=("$input")
    echo "Generated .$extension ($(probe_field "$input" codec_name))"
  else
    echo "FAIL generate .$extension"
    tail -n 4 "$WORK_DIR/create-$extension.log"
    failures=$((failures + 1))
  fi
done

large_input=""
if large_input="$(make_large_input)"; then
  echo "Generated 4K fixture ($(probe_dimensions "$large_input"), $(probe_field "$large_input" codec_name))"
else
  echo "FAIL generate 4K fixture"
  tail -n 4 "$WORK_DIR/create-4k.log"
  failures=$((failures + 1))
fi

for input in "${inputs[@]}"; do
  input_extension="${input##*.}"
  output="$WORK_DIR/${input_extension}-to-hevc.mp4"
  if run_conversion "$input" "$output" -b:v 4000k -maxrate 4000k -bufsize 8000k -pix_fmt yuv420p; then
    codec="$(probe_field "$output" codec_name)"
    pix_fmt="$(probe_field "$output" pix_fmt)"
    if [[ "$codec" == "hevc" ]]; then
      echo "OK   .$input_extension -> HEVC MP4 ($codec, $pix_fmt)"
    else
      echo "FAIL .$input_extension -> HEVC MP4 reported codec $codec"
      failures=$((failures + 1))
    fi
  else
    echo "FAIL .$input_extension -> HEVC MP4"
    tail -n 5 "$WORK_DIR/$(basename "$output").log"
    failures=$((failures + 1))
  fi
done

if [[ "${#inputs[@]}" -gt 0 ]]; then
  output="$WORK_DIR/main10.mov"
  if run_conversion "${inputs[0]}" "$output" -b:v 6000k -maxrate 6000k -bufsize 12000k -pix_fmt p010le -profile:v main10; then
    codec="$(probe_field "$output" codec_name)"
    pix_fmt="$(probe_field "$output" pix_fmt)"
    profile="$(probe_field "$output" profile)"
    if [[ "$codec" == "hevc" && "$pix_fmt" == "yuv420p10le" ]]; then
      echo "OK   HEVC Main10 MOV ($codec, $profile, $pix_fmt)"
    else
      echo "FAIL HEVC Main10 MOV reported $codec, $profile, $pix_fmt"
      failures=$((failures + 1))
    fi
  else
    echo "FAIL HEVC Main10 MOV"
    tail -n 5 "$WORK_DIR/$(basename "$output").log"
    failures=$((failures + 1))
  fi
fi

if [[ -n "$large_input" ]]; then
  output="$WORK_DIR/4k-to-1080p-hevc.mp4"
  scale_filter='scale=w=min(1920\,iw):h=min(1080\,ih):force_original_aspect_ratio=decrease:force_divisible_by=2'
  if run_conversion "$large_input" "$output" -vf "$scale_filter" -b:v 4000k -maxrate 4000k -bufsize 8000k -pix_fmt yuv420p; then
    codec="$(probe_field "$output" codec_name)"
    dimensions="$(probe_dimensions "$output")"
    if [[ "$codec" == "hevc" && "$dimensions" == "1920x1080" ]]; then
      echo "OK   4K -> 1080p HEVC MP4 ($codec, $dimensions)"
    else
      echo "FAIL 4K -> 1080p HEVC MP4 reported $codec, $dimensions"
      failures=$((failures + 1))
    fi
  else
    echo "FAIL 4K -> 1080p HEVC MP4"
    tail -n 5 "$WORK_DIR/$(basename "$output").log"
    failures=$((failures + 1))
  fi
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All video conversion smoke tests passed."
else
  echo "$failures video conversion smoke test(s) failed."
  exit 1
fi
