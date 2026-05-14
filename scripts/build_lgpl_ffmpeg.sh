#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${FFMPEG_LGPL_WORK_DIR:-$ROOT_DIR/vendor/ffmpeg-lgpl}"
SRC_DIR="$WORK_DIR/src"
PREFIX_DIR="$WORK_DIR/prefix"
ARCH="${ARCH:-arm64}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

LIBOGG_VERSION="${LIBOGG_VERSION:-1.3.5}"
LIBVORBIS_VERSION="${LIBVORBIS_VERSION:-1.3.7}"
LIBOPUS_VERSION="${LIBOPUS_VERSION:-1.5.2}"
LAME_VERSION="${LAME_VERSION:-3.100}"
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.1}"

export MACOSX_DEPLOYMENT_TARGET
export SDKROOT
export PATH="$PREFIX_DIR/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig"
export CFLAGS="-arch $ARCH -isysroot $SDKROOT -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -I$PREFIX_DIR/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch $ARCH -isysroot $SDKROOT -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -L$PREFIX_DIR/lib"

download() {
  local url="$1"
  local output="$2"

  if [[ -f "$output" ]]; then
    return
  fi

  echo "Downloading $(basename "$output")"
  curl -L --fail --retry 3 --output "$output" "$url"
}

extract() {
  local archive="$1"
  local target="$2"

  if [[ -d "$target" ]]; then
    return
  fi

  echo "Extracting $(basename "$archive")"
  tar -xf "$archive" -C "$SRC_DIR"
}

run_configure_make_install() {
  local dir="$1"
  shift

  echo "Building $(basename "$dir")"
  (
    cd "$dir"
    ./configure "$@"
    make -j"$JOBS"
    make install
  )
}

patch_libvorbis_darwin_flags() {
  local dir="$1"

  # libvorbis 1.3.7 still injects -force_cpusubtype_ALL on Darwin.
  # Modern Apple arm64 linkers reject that obsolete flag.
  for file in "$dir/configure" "$dir/Makefile" "$dir/lib/Makefile"; do
    if [[ -f "$file" ]]; then
      perl -pi -e 's/(^|\s)-force_cpusubtype_ALL(\s|$)/ /g' "$file"
    fi
  done
}

validate_binary() {
  local ffmpeg="$1"
  local buildconf

  echo
  echo "Validating $ffmpeg"

  buildconf="$("$ffmpeg" -hide_banner -buildconf 2>/dev/null)"
  for flag in --enable-gpl --enable-nonfree --enable-version3; do
    if grep -q -- "$flag" <<<"$buildconf"; then
      echo "error: FFmpeg build contains forbidden flag: $flag" >&2
      exit 1
    fi
  done

  "$ffmpeg" -hide_banner -encoders | grep -q 'libvorbis' || {
    echo "error: FFmpeg build does not include libvorbis encoder." >&2
    exit 1
  }
  "$ffmpeg" -hide_banner -encoders | grep -q 'libmp3lame' || {
    echo "error: FFmpeg build does not include libmp3lame encoder." >&2
    exit 1
  }
  "$ffmpeg" -hide_banner -encoders | grep -q 'libopus' || {
    echo "error: FFmpeg build does not include libopus encoder." >&2
    exit 1
  }

  if command -v otool >/dev/null 2>&1 &&
    otool -L "$ffmpeg" | grep -E '/opt/homebrew|/usr/local' >/dev/null; then
    echo "error: FFmpeg links to Homebrew/local libraries; build is not self-contained." >&2
    otool -L "$ffmpeg" >&2
    exit 1
  fi

  echo "LGPL-compatible bundled FFmpeg candidate:"
  "$ffmpeg" -hide_banner -version | head -n 4
}

mkdir -p "$SRC_DIR" "$PREFIX_DIR"

download "https://downloads.xiph.org/releases/ogg/libogg-$LIBOGG_VERSION.tar.xz" "$SRC_DIR/libogg-$LIBOGG_VERSION.tar.xz"
download "https://downloads.xiph.org/releases/vorbis/libvorbis-$LIBVORBIS_VERSION.tar.xz" "$SRC_DIR/libvorbis-$LIBVORBIS_VERSION.tar.xz"
download "https://downloads.xiph.org/releases/opus/opus-$LIBOPUS_VERSION.tar.gz" "$SRC_DIR/opus-$LIBOPUS_VERSION.tar.gz"
download "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" "$SRC_DIR/lame-$LAME_VERSION.tar.gz"
download "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz"

extract "$SRC_DIR/libogg-$LIBOGG_VERSION.tar.xz" "$SRC_DIR/libogg-$LIBOGG_VERSION"
extract "$SRC_DIR/libvorbis-$LIBVORBIS_VERSION.tar.xz" "$SRC_DIR/libvorbis-$LIBVORBIS_VERSION"
extract "$SRC_DIR/opus-$LIBOPUS_VERSION.tar.gz" "$SRC_DIR/opus-$LIBOPUS_VERSION"
extract "$SRC_DIR/lame-$LAME_VERSION.tar.gz" "$SRC_DIR/lame-$LAME_VERSION"
extract "$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz" "$SRC_DIR/ffmpeg-$FFMPEG_VERSION"

patch_libvorbis_darwin_flags "$SRC_DIR/libvorbis-$LIBVORBIS_VERSION"

run_configure_make_install "$SRC_DIR/libogg-$LIBOGG_VERSION" \
  --prefix="$PREFIX_DIR" \
  --disable-shared \
  --enable-static

run_configure_make_install "$SRC_DIR/libvorbis-$LIBVORBIS_VERSION" \
  --prefix="$PREFIX_DIR" \
  --disable-shared \
  --enable-static

run_configure_make_install "$SRC_DIR/opus-$LIBOPUS_VERSION" \
  --prefix="$PREFIX_DIR" \
  --disable-shared \
  --enable-static \
  --disable-extra-programs \
  --disable-doc

run_configure_make_install "$SRC_DIR/lame-$LAME_VERSION" \
  --prefix="$PREFIX_DIR" \
  --disable-shared \
  --enable-static \
  --disable-frontend

echo "Building ffmpeg-$FFMPEG_VERSION"
(
  cd "$SRC_DIR/ffmpeg-$FFMPEG_VERSION"
  ./configure \
    --prefix="$PREFIX_DIR" \
    --cc="$(xcrun --find clang)" \
    --arch="$ARCH" \
    --target-os=darwin \
    --sysroot="$SDKROOT" \
    --pkg-config-flags="--static" \
    --extra-cflags="-I$PREFIX_DIR/include $CFLAGS" \
    --extra-ldflags="-L$PREFIX_DIR/lib $LDFLAGS" \
    --disable-autodetect \
    --disable-everything \
    --disable-shared \
    --enable-static \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --disable-ffprobe \
    --disable-gpl \
    --disable-nonfree \
    --enable-protocol=file \
    --enable-protocol=pipe \
    --enable-demuxer=aac \
    --enable-demuxer=aiff \
    --enable-demuxer=flac \
    --enable-demuxer=mov \
    --enable-demuxer=mp3 \
    --enable-demuxer=ogg \
    --enable-demuxer=wav \
    --enable-muxer=flac \
    --enable-muxer=mp3 \
    --enable-muxer=ogg \
    --enable-muxer=opus \
    --enable-decoder=aac \
    --enable-decoder=flac \
    --enable-decoder=mp3 \
    --enable-decoder=opus \
    --enable-decoder=pcm_s16be \
    --enable-decoder=pcm_s16le \
    --enable-decoder=vorbis \
    --enable-encoder=flac \
    --enable-encoder=libmp3lame \
    --enable-encoder=libopus \
    --enable-encoder=libvorbis \
    --enable-parser=aac \
    --enable-parser=flac \
    --enable-parser=mpegaudio \
    --enable-parser=opus \
    --enable-parser=vorbis \
    --enable-filter=aformat \
    --enable-filter=anull \
    --enable-filter=aresample \
    --enable-filter=format \
    --enable-filter=pan \
    --enable-filter=volume \
    --enable-swresample \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-libvorbis
  make -j"$JOBS"
  make install
)

validate_binary "$PREFIX_DIR/bin/ffmpeg"

echo
echo "Build complete:"
echo "$PREFIX_DIR/bin/ffmpeg"
echo
echo "Bundle with:"
echo "BUNDLED_FFMPEG=\"$PREFIX_DIR/bin/ffmpeg\" ./scripts/build_app.sh"
