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

WORK_DIR="$(mktemp -d /tmp/gphilcoder-audio-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

ENCODERS="$("$FFMPEG" -hide_banner -encoders 2>/dev/null || true)"
GENERATOR_FFMPEG="${GENERATOR_FFMPEG:-$FFMPEG}"
GENERATOR_ENCODERS="$("$GENERATOR_FFMPEG" -hide_banner -encoders 2>/dev/null || true)"
HAS_LIBVORBIS=0
if [[ "$ENCODERS" == *"libvorbis"* ]]; then
  HAS_LIBVORBIS=1
fi
GENERATOR_HAS_LIBVORBIS=0
if [[ "$GENERATOR_ENCODERS" == *"libvorbis"* ]]; then
  GENERATOR_HAS_LIBVORBIS=1
fi

INPUT_FORMATS=(wav aiff flac mp3 m4a aac ogg opus wv)
OUTPUT_FORMATS=(mp3 ogg opus flac wv)

input_args() {
  case "$1" in
    wav) echo "-codec:a pcm_s16le" ;;
    aiff) echo "-codec:a pcm_s16be" ;;
    flac) echo "-codec:a flac" ;;
    mp3) echo "-codec:a libmp3lame -q:a 2" ;;
    m4a) echo "-codec:a aac -b:a 192k" ;;
    aac) echo "-codec:a aac -b:a 192k -f adts" ;;
    ogg)
      if [[ "$GENERATOR_HAS_LIBVORBIS" -eq 1 ]]; then
        echo "-codec:a libvorbis -ac 2 -qscale:a 5"
      else
        echo "-codec:a vorbis -ac 2 -qscale:a 5 -strict -2"
      fi
      ;;
    opus) echo "-codec:a libopus -b:a 128k -vbr on" ;;
    wv) echo "-codec:a wavpack" ;;
  esac
}

output_args() {
  case "$1" in
    mp3) echo "-codec:a libmp3lame -q:a 2" ;;
    ogg)
      if [[ "$HAS_LIBVORBIS" -eq 1 ]]; then
        echo "-codec:a libvorbis -ac 2 -qscale:a 6"
      else
        echo "-codec:a vorbis -ac 2 -qscale:a 6 -strict -2"
      fi
      ;;
    opus) echo "-codec:a libopus -b:a 192k -vbr on -compression_level 10" ;;
    flac) echo "-codec:a flac -compression_level 8" ;;
    wv) echo "-codec:a wavpack" ;;
  esac
}

make_input() {
  local format="$1"
  local output="$WORK_DIR/input.$format"
  read -r -a args <<<"$(input_args "$format")"

  if "$GENERATOR_FFMPEG" -hide_banner -nostdin -y \
    -f lavfi -i sine=frequency=440:duration=0.35 \
    "${args[@]}" "$output" >/dev/null 2>"$WORK_DIR/create-$format.log"; then
    echo "$output"
  else
    echo "SKIP input .$format ($(tail -n 1 "$WORK_DIR/create-$format.log"))" >&2
    return 1
  fi
}

make_custom_input() {
  local label="$1"
  local extension="$2"
  shift 2
  local output="$WORK_DIR/input-$label.$extension"

  if "$GENERATOR_FFMPEG" -hide_banner -nostdin -y \
    -f lavfi -i sine=frequency=440:duration=0.35 \
    "$@" "$output" >/dev/null 2>"$WORK_DIR/create-$label.log"; then
    echo "$output"
  else
    echo "SKIP input $label ($(tail -n 1 "$WORK_DIR/create-$label.log"))" >&2
    return 1
  fi
}

probe_codec() {
  "$FFPROBE" -hide_banner -v error \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$1" | head -n 1
}

failures=0
declare -a generated_inputs=()

echo "Using FFmpeg: $FFMPEG"
echo "Using generator FFmpeg: $GENERATOR_FFMPEG"
echo "Using ffprobe: $FFPROBE"
echo "Work dir: $WORK_DIR"
echo

for input_format in "${INPUT_FORMATS[@]}"; do
  if input_path="$(make_input "$input_format")"; then
    generated_inputs+=("$input_path")
    echo "Generated .$input_format ($(probe_codec "$input_path"))"
  fi
done

if input_path="$(make_custom_input wav-s24le wav -codec:a pcm_s24le)"; then
  generated_inputs+=("$input_path")
  echo "Generated .wav 24-bit ($(probe_codec "$input_path"))"
fi

if input_path="$(make_custom_input flac-s24 flac -af aformat=sample_fmts=s32 -bits_per_raw_sample 24 -codec:a flac)"; then
  generated_inputs+=("$input_path")
  echo "Generated .flac 24-bit ($(probe_codec "$input_path"))"
fi

if input_path="$(make_custom_input wv-s24 wv -af aformat=sample_fmts=s32 -bits_per_raw_sample 24 -codec:a wavpack)"; then
  generated_inputs+=("$input_path")
  echo "Generated .wv 24-bit ($(probe_codec "$input_path"))"
fi

if input_path="$(make_custom_input wv-s32 wv -af aformat=sample_fmts=s32 -codec:a wavpack)"; then
  generated_inputs+=("$input_path")
  echo "Generated .wv 32-bit ($(probe_codec "$input_path"))"
fi

echo

for input_path in "${generated_inputs[@]}"; do
  input_format="${input_path##*.}"
  input_label="$(basename "${input_path%.*}")"

  for output_format in "${OUTPUT_FORMATS[@]}"; do
    if [[ "$input_format" == "$output_format" ]]; then
      echo "SKIP .$input_format -> .$output_format (same-format re-encode)"
      continue
    fi

    output_path="$WORK_DIR/${input_label}-to-${output_format}.$output_format"
    read -r -a args <<<"$(output_args "$output_format")"

    if "$FFMPEG" -hide_banner -nostdin -y \
      -i "$input_path" -vn "${args[@]}" "$output_path" \
      >/dev/null 2>"$WORK_DIR/${input_format}-to-${output_format}.log"; then
      echo "OK   .$input_format -> .$output_format ($(probe_codec "$output_path"))"
    else
      echo "FAIL .$input_format -> .$output_format"
      tail -n 3 "$WORK_DIR/${input_format}-to-${output_format}.log"
      failures=$((failures + 1))
    fi
  done
done

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All conversion smoke tests passed."
else
  echo "$failures conversion smoke test(s) failed."
  exit 1
fi
