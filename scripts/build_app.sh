#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="GPhilCoder"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SOURCE_ICON="$ROOT_DIR/Sources/assets/appicon.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
BUNDLED_FFMPEG="${BUNDLED_FFMPEG:-}"
ALLOW_NON_LGPL_FFMPEG="${ALLOW_NON_LGPL_FFMPEG:-0}"

validate_lgpl_ffmpeg() {
  local ffmpeg_path="$1"
  local buildconf

  if ! buildconf="$("$ffmpeg_path" -hide_banner -buildconf 2>/dev/null)"; then
    echo "warning: could not inspect FFmpeg build configuration for LGPL compatibility." >&2
    return 0
  fi

  local forbidden_flags=()
  for flag in --enable-gpl --enable-nonfree --enable-version3; do
    if grep -q -- "$flag" <<<"$buildconf"; then
      forbidden_flags+=("$flag")
    fi
  done

  if [[ "${#forbidden_flags[@]}" -gt 0 ]]; then
    echo "error: bundled FFmpeg was built with non-LGPL-compatible flag(s): ${forbidden_flags[*]}" >&2
    echo "Use an LGPL FFmpeg build without --enable-gpl, --enable-nonfree, or --enable-version3." >&2
    echo "Set ALLOW_NON_LGPL_FFMPEG=1 only for private experiments." >&2
    if [[ "$ALLOW_NON_LGPL_FFMPEG" != "1" ]]; then
      exit 1
    fi
    echo "warning: continuing despite non-LGPL FFmpeg flags because ALLOW_NON_LGPL_FFMPEG=1." >&2
  fi
}

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"

if [[ -n "$BUNDLED_FFMPEG" ]]; then
  if [[ ! -x "$BUNDLED_FFMPEG" ]]; then
    echo "BUNDLED_FFMPEG must point to an executable ffmpeg binary: $BUNDLED_FFMPEG" >&2
    exit 1
  fi

  validate_lgpl_ffmpeg "$BUNDLED_FFMPEG"

  cp "$BUNDLED_FFMPEG" "$RESOURCES_DIR/ffmpeg"
  chmod 755 "$RESOURCES_DIR/ffmpeg"

  if ! "$RESOURCES_DIR/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q 'libvorbis'; then
    echo "warning: bundled FFmpeg does not report libvorbis; Ogg bitrate mode will remain unavailable." >&2
  fi

  if command -v otool >/dev/null 2>&1 && otool -L "$RESOURCES_DIR/ffmpeg" | grep -E '/opt/homebrew|/usr/local' >/dev/null; then
    echo "warning: bundled FFmpeg links to Homebrew libraries. Use a self-contained/static FFmpeg build for distribution." >&2
  fi
fi

if [[ -f "$SOURCE_ICON" ]]; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.gphil.coder</string>
  <key>CFBundleName</key>
  <string>GPhilCoder</string>
  <key>CFBundleDisplayName</key>
  <string>GPhilCoder</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built $APP_DIR"
