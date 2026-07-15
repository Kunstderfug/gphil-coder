#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/app_store_common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/app_store_upload_retry.sh"

usage() {
  cat <<'USAGE'
usage: scripts/upload_macos_app_store.sh [options]

Builds, signs, packages, uploads, checks status, and updates TestFlight notes
for the macOS App Store build.

Options:
  --upload-only                 Upload existing dist/GPhil MediaFlow-AppStore.pkg.
  --skip-testflight-notes       Do not update TestFlight release notes.
  --skip-build-status           Do not check altool build status after upload.
  --dry-run                     Resolve credentials/profile/build number, then exit before build/upload.
  --bundle-id <id>              Bundle id. Default: com.gphil.coder.
  --marketing-version <value>   App version string. Default: MARKETING_VERSION or 1.0.
  --build-number <value>        Build number. Default: next App Store Connect build number.
  --provisioning-profile <path> Mac App Store provisioning profile.
  --release-notes <path>        Release notes file for TestFlight.
  --pkg <path>                  Package to upload in --upload-only mode.
  -h, --help                    Show this help.

Environment:
  APP_STORE_ENV_FILE            Optional credentials env file. If absent, this script
                                falls back to ../gphil-flutter/app_store_keys/app_store.env
                                on this machine when present.
USAGE
}

UPLOAD_ONLY=0
SKIP_TESTFLIGHT_NOTES=0
SKIP_BUILD_STATUS=0
DRY_RUN=0
BUNDLE_ID="${APPSTORE_MACOS_BUNDLE_ID:-${APPSTORE_BUNDLE_ID:-${BUNDLE_IDENTIFIER:-com.gphil.coder}}}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"
PKG_FILE="${PKG_FILE:-$ROOT_DIR/dist/GPhil MediaFlow-AppStore.pkg}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upload-only)
      UPLOAD_ONLY=1
      shift
      ;;
    --skip-testflight-notes)
      SKIP_TESTFLIGHT_NOTES=1
      shift
      ;;
    --skip-build-status)
      SKIP_BUILD_STATUS=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --marketing-version)
      MARKETING_VERSION="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --provisioning-profile | --profile)
      PROVISIONING_PROFILE="${2:-}"
      shift 2
      ;;
    --release-notes)
      RELEASE_NOTES_FILE="${2:-}"
      shift 2
      ;;
    --pkg)
      PKG_FILE="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

load_app_store_env "$ROOT_DIR"
discover_app_store_api_key "$ROOT_DIR"

if [[ -z "$BUNDLE_ID" ]]; then
  echo "error: bundle id is required" >&2
  exit 1
fi

plist_value() {
  local key="$1"
  local plist="$ROOT_DIR/dist/GPhil MediaFlow.app/Contents/Info.plist"

  [[ -f "$plist" ]] || return 0
  plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true
}

if (( UPLOAD_ONLY )); then
  if [[ -z "$MARKETING_VERSION" ]]; then
    MARKETING_VERSION="$(plist_value CFBundleShortVersionString)"
  fi
  if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$(plist_value CFBundleVersion)"
  fi
else
  require_app_store_api_key
  APP_ID="$(app_store_app_id_for_bundle_id "$BUNDLE_ID")"
  if [[ -z "$APP_ID" ]]; then
    echo "error: no App Store Connect app found for bundle id '$BUNDLE_ID'" >&2
    exit 1
  fi

  if [[ -z "$BUILD_NUMBER" ]]; then
    LATEST_BUILD_NUMBER="$(latest_build_number_for_version "$APP_ID" "$MARKETING_VERSION")"
    BUILD_NUMBER="$((LATEST_BUILD_NUMBER + 1))"
    echo "==> Auto-selected build number $BUILD_NUMBER for $MARKETING_VERSION"
  fi
fi

resolve_pkg_sign_identity() {
  if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then
    printf '%s' "$PKG_SIGN_IDENTITY"
    return
  fi

  security find-identity -v 2>/dev/null \
    | awk -F '"' '/3rd Party Mac Developer Installer/ && $0 !~ /CSSMERR/ { print $2; exit }'
}

resolve_profile_and_app_identity() {
  local explicit_profile="$1"
  local bundle_id="$2"

  /usr/bin/python3 - "$ROOT_DIR" "$bundle_id" "$explicit_profile" <<'PY'
import os
import plistlib
import re
import shlex
import subprocess
import sys

root_dir, bundle_id, explicit_profile = sys.argv[1:4]

identity_output = subprocess.check_output(
    ["security", "find-identity", "-v", "-p", "codesigning"],
    text=True,
    stderr=subprocess.DEVNULL,
)
valid_identities = {}
for line in identity_output.splitlines():
    if "CSSMERR" in line:
        continue
    match = re.search(r"\)\s+([A-F0-9]{40})\s+\"([^\"]+)\"", line)
    if match:
        valid_identities[match.group(1).upper()] = match.group(2)

def profile_plist(path):
    return plistlib.loads(
        subprocess.check_output(["security", "cms", "-D", "-i", path], stderr=subprocess.DEVNULL)
    )

def cert_fingerprints(profile):
    result = []
    for cert in profile.get("DeveloperCertificates") or []:
        proc = subprocess.run(
            ["openssl", "x509", "-inform", "DER", "-noout", "-fingerprint", "-sha1"],
            input=bytes(cert),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        text = proc.stdout.decode("utf-8", "replace")
        if "=" in text:
            result.append(text.split("=", 1)[1].strip().replace(":", "").upper())
    return result

def candidate_paths():
    if explicit_profile:
        yield explicit_profile
        return

    search_roots = [
        root_dir,
        os.path.join(root_dir, "Packaging"),
        os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
        os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
    ]
    seen = set()
    skipped_names = {".build", ".swiftpm", ".git", "dist", "vendor"}
    for search_root in search_roots:
        if not os.path.isdir(search_root):
            continue
        for current_root, dirs, files in os.walk(search_root):
            dirs[:] = [name for name in dirs if name not in skipped_names]
            for name in files:
                if not (name.endswith(".provisionprofile") or name.endswith(".mobileprovision")):
                    continue
                path = os.path.join(current_root, name)
                if path in seen:
                    continue
                seen.add(path)
                yield path

matches = []
for path in candidate_paths():
    if not os.path.isfile(path):
        continue
    try:
        profile = profile_plist(path)
    except Exception:
        continue

    entitlements = profile.get("Entitlements") or {}
    app_identifier = entitlements.get("com.apple.application-identifier") or entitlements.get("application-identifier") or ""
    if not app_identifier.endswith("." + bundle_id):
        continue
    if profile.get("ProvisionedDevices"):
        continue

    matching_identity = ""
    for fingerprint in cert_fingerprints(profile):
        if fingerprint in valid_identities:
            matching_identity = fingerprint
            break
    if not matching_identity:
        continue

    score = 0
    if os.path.commonpath([os.path.abspath(root_dir), os.path.abspath(path)]) == os.path.abspath(root_dir):
        score += 20
    if "App Connect" in (profile.get("Name") or ""):
        score += 10
    matches.append((score, path, matching_identity, profile.get("Name") or ""))

if not matches:
    if explicit_profile:
        print(f"error: profile does not match bundle id '{bundle_id}' and a valid local signing identity: {explicit_profile}", file=sys.stderr)
    else:
        print(f"error: no Mac App Store provisioning profile found for '{bundle_id}' with a valid local signing identity", file=sys.stderr)
    raise SystemExit(1)

matches.sort(reverse=True)
_, path, identity, name = matches[0]
print("RESOLVED_PROVISIONING_PROFILE=" + shlex.quote(path))
print("RESOLVED_APP_SIGN_IDENTITY=" + shlex.quote(identity))
print("RESOLVED_PROVISIONING_PROFILE_NAME=" + shlex.quote(name))
PY
}

if (( ! UPLOAD_ONLY )); then
  eval "$(resolve_profile_and_app_identity "$PROVISIONING_PROFILE" "$BUNDLE_ID")"
  PROVISIONING_PROFILE="$RESOLVED_PROVISIONING_PROFILE"
  APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-$RESOLVED_APP_SIGN_IDENTITY}"
  PKG_SIGN_IDENTITY="$(resolve_pkg_sign_identity)"

  if [[ -z "$PKG_SIGN_IDENTITY" ]]; then
    echo "error: no valid 3rd Party Mac Developer Installer identity found" >&2
    exit 1
  fi

  echo "==> Using provisioning profile: $RESOLVED_PROVISIONING_PROFILE_NAME"
  if (( DRY_RUN )); then
    echo "==> Dry run:"
    echo "    bundle id: $BUNDLE_ID"
    echo "    marketing version: $MARKETING_VERSION"
    echo "    build number: $BUILD_NUMBER"
    echo "    provisioning profile: $PROVISIONING_PROFILE"
    echo "    app signing identity: $APP_SIGN_IDENTITY"
    echo "    package signing identity: $PKG_SIGN_IDENTITY"
    echo "    package path: $PKG_FILE"
    exit 0
  fi

  echo "==> Building App Store package for $BUNDLE_ID $MARKETING_VERSION ($BUILD_NUMBER)"
  SIGNING_MODE=app-store \
    BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    BUILD_NUMBER="$BUILD_NUMBER" \
    PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
    APP_SIGN_IDENTITY="$APP_SIGN_IDENTITY" \
    PKG_SIGN_IDENTITY="$PKG_SIGN_IDENTITY" \
    PKG_PATH="$PKG_FILE" \
    "$ROOT_DIR/scripts/build_app.sh"
fi

if [[ ! -f "$PKG_FILE" ]]; then
  echo "error: package not found at '$PKG_FILE'" >&2
  exit 1
fi

if (( DRY_RUN )); then
  echo "==> Dry run:"
  echo "    upload-only package: $PKG_FILE"
  echo "    bundle id: $BUNDLE_ID"
  echo "    marketing version: $MARKETING_VERSION"
  echo "    build number: $BUILD_NUMBER"
  exit 0
fi

echo "==> Uploading macOS package: $PKG_FILE"

UPLOAD_LOG="$(mktemp)"
if [[ -n "$API_KEY_ID" || -n "$API_ISSUER_ID" || -n "$API_KEY_PATH" ]]; then
  require_app_store_api_key
  KEY_DIR="$(dirname "$API_KEY_PATH")"
  echo "==> Using App Store Connect API key auth (Key ID: $API_KEY_ID)"
  set +e
  API_PRIVATE_KEYS_DIR="$KEY_DIR" run_app_store_upload_with_retries \
    xcrun altool \
    --upload-app \
    --type macos \
    --file "$PKG_FILE" \
    --apiKey "$API_KEY_ID" \
    --apiIssuer "$API_ISSUER_ID" 2>&1 | tee "$UPLOAD_LOG"
  UPLOAD_STATUS=${PIPESTATUS[0]}
  set -e
else
  APPLE_ID="${APPSTORE_APPLE_ID:-}"
  APPLE_PASSWORD="${APPSTORE_APP_PASSWORD:-}"
  ITC_PROVIDER="${APPSTORE_ITC_PROVIDER:-}"

  : "${APPLE_ID:?Set APPSTORE_APPLE_ID in $APP_STORE_ENV_FILE or shell env}"
  : "${APPLE_PASSWORD:?Set APPSTORE_APP_PASSWORD in $APP_STORE_ENV_FILE or shell env}"

  set +e
  if [[ -n "$ITC_PROVIDER" ]]; then
    run_app_store_upload_with_retries \
      xcrun iTMSTransporter \
      -m upload \
      -assetFile "$PKG_FILE" \
      -u "$APPLE_ID" \
      -p "$APPLE_PASSWORD" \
      -itc_provider "$ITC_PROVIDER" \
      -v informational 2>&1 | tee "$UPLOAD_LOG"
  else
    run_app_store_upload_with_retries \
      xcrun iTMSTransporter \
      -m upload \
      -assetFile "$PKG_FILE" \
      -u "$APPLE_ID" \
      -p "$APPLE_PASSWORD" \
      -v informational 2>&1 | tee "$UPLOAD_LOG"
  fi
  UPLOAD_STATUS=${PIPESTATUS[0]}
  set -e
fi

if (( UPLOAD_STATUS != 0 )); then
  rm -f "$UPLOAD_LOG"
  exit "$UPLOAD_STATUS"
fi

DELIVERY_UUID="$(
  sed -n -E 's/.*Delivery UUID:[[:space:]]*([A-Fa-f0-9-]+).*/\1/p' "$UPLOAD_LOG" | tail -n 1
)"
rm -f "$UPLOAD_LOG"

echo "==> macOS upload complete"

if (( ! SKIP_BUILD_STATUS )) && [[ -n "$DELIVERY_UUID" ]] && [[ -n "$API_KEY_ID" && -n "$API_ISSUER_ID" ]]; then
  echo "==> Checking build status for delivery $DELIVERY_UUID"
  API_PRIVATE_KEYS_DIR="$(dirname "$API_KEY_PATH")" xcrun altool \
    --build-status \
    --delivery-id "$DELIVERY_UUID" \
    --apiKey "$API_KEY_ID" \
    --apiIssuer "$API_ISSUER_ID"
fi

if (( SKIP_TESTFLIGHT_NOTES )); then
  echo "==> Skipping TestFlight release notes (--skip-testflight-notes)"
else
  echo "==> Applying TestFlight release notes (if available)"
  RELEASE_NOTES_FILE="$RELEASE_NOTES_FILE" \
    BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    BUILD_NUMBER="$BUILD_NUMBER" \
    "$ROOT_DIR/scripts/set_testflight_release_notes.sh"
fi
