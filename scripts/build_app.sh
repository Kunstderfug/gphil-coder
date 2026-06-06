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
DEFAULT_BUNDLED_FFMPEG="$ROOT_DIR/vendor/ffmpeg-lgpl/prefix/bin/ffmpeg"
BUNDLED_FFMPEG="${BUNDLED_FFMPEG:-$DEFAULT_BUNDLED_FFMPEG}"
ALLOW_NON_LGPL_FFMPEG="${ALLOW_NON_LGPL_FFMPEG:-0}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.gphil.coder}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_CATEGORY="${APP_CATEGORY:-public.app-category.music}"
SIGNING_MODE="${SIGNING_MODE:-local}"
APP_STORE_BUILD="${APP_STORE_BUILD:-0}"
APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-$ROOT_DIR/Packaging/GPhilCoder.entitlements}"
HELPER_ENTITLEMENTS="${HELPER_ENTITLEMENTS:-$ROOT_DIR/Packaging/GPhilCoderFFmpeg.entitlements}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-Apple Distribution}}"
PKG_SIGN_IDENTITY="${PKG_SIGN_IDENTITY:-3rd Party Mac Developer Installer}"
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
CODE_SIGN_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-1}"
SKIP_PACKAGE="${SKIP_PACKAGE:-0}"
PKG_PATH="${PKG_PATH:-$DIST_DIR/$APP_NAME-AppStore.pkg}"

case "$SIGNING_MODE" in
  app-store)
    APP_STORE_BUILD=1
    ;;
  local | none)
    ;;
  *)
    echo "SIGNING_MODE must be one of: local, app-store, none" >&2
    exit 1
    ;;
esac

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

validate_distribution_ffmpeg() {
  local ffmpeg_path="$1"

  validate_lgpl_ffmpeg "$ffmpeg_path"

  if command -v otool >/dev/null 2>&1 && otool -L "$ffmpeg_path" | grep -E '/opt/homebrew|/usr/local' >/dev/null; then
    if [[ "$APP_STORE_BUILD" == "1" ]]; then
      echo "error: App Store builds require a self-contained FFmpeg binary." >&2
      echo "The selected FFmpeg links to Homebrew/local libraries:" >&2
      otool -L "$ffmpeg_path" >&2
      exit 1
    fi

    echo "warning: bundled FFmpeg links to Homebrew libraries. Use a self-contained/static FFmpeg build for distribution." >&2
  fi
}

sign_local_bundle() {
  if ! command -v codesign >/dev/null 2>&1; then
    echo "warning: codesign not found; app bundle was not signed." >&2
    return
  fi

  if [[ -x "$MACOS_DIR/ffmpeg" ]]; then
    codesign --force --sign - "$MACOS_DIR/ffmpeg"
  fi
  codesign --force --sign - "$APP_DIR"
}

sign_app_store_bundle() {
  local codesign_options=(--options runtime)
  local app_entitlements_for_signing="$APP_ENTITLEMENTS"

  if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
    echo "App entitlement file not found: $APP_ENTITLEMENTS" >&2
    exit 1
  fi
  if [[ ! -f "$HELPER_ENTITLEMENTS" ]]; then
    echo "FFmpeg helper entitlement file not found: $HELPER_ENTITLEMENTS" >&2
    exit 1
  fi

  if [[ "$CODE_SIGN_TIMESTAMP" == "1" ]]; then
    codesign_options+=(--timestamp)
  fi

  if [[ -n "$PROVISIONING_PROFILE" ]]; then
    if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
      echo "Provisioning profile not found: $PROVISIONING_PROFILE" >&2
      exit 1
    fi
    cp "$PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
    mkdir -p "$ROOT_DIR/.build/signing"
    app_entitlements_for_signing="$ROOT_DIR/.build/signing/$APP_NAME.entitlements"
    /usr/bin/python3 - "$APP_ENTITLEMENTS" "$PROVISIONING_PROFILE" "$app_entitlements_for_signing" <<'PY'
import plistlib
import subprocess
import sys

base_path, profile_path, output_path = sys.argv[1:4]
with open(base_path, "rb") as handle:
    entitlements = plistlib.load(handle)

profile_plist = plistlib.loads(
    subprocess.check_output(["security", "cms", "-D", "-i", profile_path])
)
profile_entitlements = profile_plist.get("Entitlements", {})
for key in (
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "keychain-access-groups",
):
    if key in profile_entitlements:
        entitlements[key] = profile_entitlements[key]

with open(output_path, "wb") as handle:
    plistlib.dump(entitlements, handle, fmt=plistlib.FMT_XML, sort_keys=True)
PY
  fi

  if [[ -x "$MACOS_DIR/ffmpeg" ]]; then
    codesign \
      --force \
      --sign "$APP_SIGN_IDENTITY" \
      --identifier "$BUNDLE_IDENTIFIER.ffmpeg" \
      --entitlements "$HELPER_ENTITLEMENTS" \
      "${codesign_options[@]}" \
      "$MACOS_DIR/ffmpeg"
  fi

  codesign \
    --force \
    --sign "$APP_SIGN_IDENTITY" \
    --entitlements "$app_entitlements_for_signing" \
    "${codesign_options[@]}" \
    "$APP_DIR"

  codesign --verify --strict --verbose=2 "$APP_DIR"

  if [[ "$SKIP_PACKAGE" == "1" ]]; then
    return
  fi

  rm -f "$PKG_PATH"
  productbuild \
    --component "$APP_DIR" /Applications \
    --sign "$PKG_SIGN_IDENTITY" \
    "$PKG_PATH"

  pkgutil --check-signature "$PKG_PATH"
}

cd "$ROOT_DIR"

swift_build_args=(swift build -c "$CONFIGURATION")
if [[ "$APP_STORE_BUILD" == "1" ]]; then
  swift_build_args+=(-Xswiftc -DAPP_STORE)
fi
"${swift_build_args[@]}"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"

if [[ "$APP_STORE_BUILD" == "1" && -z "$BUNDLED_FFMPEG" ]]; then
  echo "App Store builds must bundle FFmpeg inside the app." >&2
  exit 1
fi

if [[ -n "$BUNDLED_FFMPEG" ]]; then
  if [[ ! -x "$BUNDLED_FFMPEG" ]]; then
    echo "BUNDLED_FFMPEG must point to an executable ffmpeg binary: $BUNDLED_FFMPEG" >&2
    if [[ "$BUNDLED_FFMPEG" == "$DEFAULT_BUNDLED_FFMPEG" ]]; then
      echo "Run ./scripts/build_lgpl_ffmpeg.sh first, or pass BUNDLED_FFMPEG=/path/to/ffmpeg." >&2
    fi
    exit 1
  fi

  validate_distribution_ffmpeg "$BUNDLED_FFMPEG"

  cp "$BUNDLED_FFMPEG" "$MACOS_DIR/ffmpeg"
  chmod 755 "$MACOS_DIR/ffmpeg"

  if ! "$MACOS_DIR/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q 'libvorbis'; then
    echo "warning: bundled FFmpeg does not report libvorbis; Ogg bitrate mode will remain unavailable." >&2
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
  <string>$BUNDLE_IDENTIFIER</string>
  <key>CFBundleName</key>
  <string>GPhilCoder</string>
  <key>CFBundleDisplayName</key>
  <string>GPhilCoder</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>$APP_CATEGORY</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
</dict>
</plist>
PLIST

case "$SIGNING_MODE" in
  app-store)
    sign_app_store_bundle
    ;;
  local)
    sign_local_bundle
    ;;
  none)
    echo "warning: SIGNING_MODE=none; app bundle was not signed." >&2
    ;;
esac

echo "Built $APP_DIR"
if [[ "$SIGNING_MODE" == "app-store" && "$SKIP_PACKAGE" != "1" ]]; then
  echo "Built $PKG_PATH"
fi
