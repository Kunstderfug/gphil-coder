#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/app_store_common.sh"

usage() {
  cat <<'USAGE'
usage: scripts/set_testflight_release_notes.sh [options]

Options:
  --bundle-id <id>             Bundle id. Defaults to APPSTORE_MACOS_BUNDLE_ID,
                               APPSTORE_BUNDLE_ID, BUNDLE_IDENTIFIER, or com.gphil.coder.
  --marketing-version <value>  App version string. Defaults to MARKETING_VERSION or the built app plist.
  --build-number <value>       Build number. Defaults to BUILD_NUMBER or the built app plist.
  --release-notes <path>       Markdown/plain-text notes file. Defaults to releases/build_<build>/testflight_release.md.
  -h, --help                   Show this help.
USAGE
}

BUNDLE_ID="${APPSTORE_MACOS_BUNDLE_ID:-${APPSTORE_BUNDLE_ID:-${BUNDLE_IDENTIFIER:-com.gphil.coder}}}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"
RELEASE_NOTES_DATE="${RELEASE_NOTES_DATE:-$(date +%F)}"
NOTES_LOCALE="${APPSTORE_TESTFLIGHT_NOTES_LOCALE:-en-US}"
NOTES_MAX_LENGTH="${APPSTORE_TESTFLIGHT_NOTES_MAX_LENGTH:-4000}"
WAIT_SECONDS="${APPSTORE_TESTFLIGHT_NOTES_WAIT_SECONDS:-900}"
POLL_SECONDS="${APPSTORE_TESTFLIGHT_NOTES_POLL_SECONDS:-20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --release-notes)
      RELEASE_NOTES_FILE="${2:-}"
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

plist_value() {
  local key="$1"
  local plist="$ROOT_DIR/dist/GPhilCoder.app/Contents/Info.plist"

  [[ -f "$plist" ]] || return 0
  plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true
}

if [[ -z "$MARKETING_VERSION" ]]; then
  MARKETING_VERSION="$(plist_value CFBundleShortVersionString)"
fi
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(plist_value CFBundleVersion)"
fi

if [[ -z "$MARKETING_VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "error: set MARKETING_VERSION and BUILD_NUMBER, or build the app first." >&2
  exit 1
fi

if [[ -z "$API_KEY_ID" || -z "$API_ISSUER_ID" ]]; then
  echo "==> Skipping TestFlight notes: APPSTORE_API_KEY_ID / APPSTORE_API_ISSUER_ID not configured"
  exit 0
fi
require_app_store_api_key

resolve_release_notes_file() {
  local build_release_notes_file="$ROOT_DIR/releases/build_${BUILD_NUMBER}/testflight_release.md"
  local legacy_release_notes_file="$ROOT_DIR/releases/$RELEASE_NOTES_DATE/testflight_release.md"

  if [[ -n "$RELEASE_NOTES_FILE" ]]; then
    printf '%s' "$RELEASE_NOTES_FILE"
    return
  fi

  if [[ -f "$build_release_notes_file" ]]; then
    printf '%s' "$build_release_notes_file"
    return
  fi

  if [[ -f "$legacy_release_notes_file" ]]; then
    echo "==> Using legacy date-based release notes file: $legacy_release_notes_file" >&2
    printf '%s' "$legacy_release_notes_file"
    return
  fi

  printf '%s' "$build_release_notes_file"
}

RELEASE_NOTES_FILE="$(resolve_release_notes_file)"

if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
  echo "==> Skipping TestFlight notes: release notes file not found at '$RELEASE_NOTES_FILE'"
  exit 0
fi

extract_release_notes_text() {
  local source_file="$1"
  local parsed_notes

  parsed_notes="$(
    awk '
      BEGIN { in_whats_new = 0 }
      {
        gsub(/\r$/, "", $0)
      }
      tolower($0) ~ /^[[:space:]]*what( is|'\''s|s)? new:?[[:space:]]*$/ {
        in_whats_new = 1
        next
      }
      {
        if (in_whats_new == 1) {
          print $0
        }
      }
    ' "$source_file"
  )"

  if [[ -z "${parsed_notes//[[:space:]]/}" ]]; then
    parsed_notes="$(cat "$source_file")"
  fi

  printf '%s\n' "$parsed_notes" \
    | sed -E 's/\r$//; s/^[[:space:]]*#{1,6}[[:space:]]*//'
}

RELEASE_NOTES_TEXT="$(extract_release_notes_text "$RELEASE_NOTES_FILE")"
if [[ -z "${RELEASE_NOTES_TEXT//[[:space:]]/}" ]]; then
  echo "==> Skipping TestFlight notes: '$RELEASE_NOTES_FILE' is empty"
  exit 0
fi

if [[ "$NOTES_MAX_LENGTH" =~ ^[0-9]+$ ]]; then
  if (( ${#RELEASE_NOTES_TEXT} > NOTES_MAX_LENGTH )); then
    RELEASE_NOTES_TEXT="${RELEASE_NOTES_TEXT:0:NOTES_MAX_LENGTH}"
    echo "==> Truncated release notes to $NOTES_MAX_LENGTH characters"
  fi
fi

APP_ID="$(app_store_app_id_for_bundle_id "$BUNDLE_ID")"
if [[ -z "$APP_ID" ]]; then
  echo "error: no App Store Connect app found for bundle id '$BUNDLE_ID'" >&2
  exit 1
fi

echo "==> Waiting for macOS build $MARKETING_VERSION ($BUILD_NUMBER) to appear in App Store Connect"

DEADLINE_EPOCH="$(( $(date +%s) + WAIT_SECONDS ))"
BUILD_ID=""

while (( $(date +%s) <= DEADLINE_EPOCH )); do
  JWT_TOKEN="$(create_jwt_token)"
  BUILD_RESPONSE_FILE="$(mktemp)"
  BUILD_ENDPOINT="/v1/builds?filter[app]=$(urlencode "$APP_ID")&filter[version]=$(urlencode "$BUILD_NUMBER")&limit=50&sort=-uploadedDate&include=preReleaseVersion"

  BUILD_STATUS_CODE="$(asc_request "$JWT_TOKEN" "GET" "$BUILD_ENDPOINT" "$BUILD_RESPONSE_FILE")"
  if (( BUILD_STATUS_CODE >= 200 && BUILD_STATUS_CODE < 300 )); then
    BUILD_ID="$(
      /usr/bin/python3 - "$BUILD_RESPONSE_FILE" "$MARKETING_VERSION" <<'PY'
import json
import sys

payload_path = sys.argv[1]
target_app_version = sys.argv[2]

payload = json.load(open(payload_path, "r", encoding="utf-8"))
included_versions = {}
for item in payload.get("included") or []:
    if item.get("type") == "preReleaseVersions":
        attrs = item.get("attributes") or {}
        included_versions[item.get("id")] = {
            "version": attrs.get("version"),
            "platform": attrs.get("platform"),
        }

for build in payload.get("data") or []:
    rel = ((build.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}
    pre_release = included_versions.get(rel.get("id")) or {}
    if (pre_release.get("platform") or "") != "MAC_OS":
        continue
    if target_app_version and pre_release.get("version") and pre_release.get("version") != target_app_version:
        continue
    print(build.get("id", ""))
    break
PY
    )"
  else
    echo "==> Build lookup retry: App Store Connect returned HTTP $BUILD_STATUS_CODE"
  fi

  rm -f "$BUILD_RESPONSE_FILE"

  if [[ -n "$BUILD_ID" ]]; then
    break
  fi

  sleep "$POLL_SECONDS"
done

if [[ -z "$BUILD_ID" ]]; then
  echo "error: timed out waiting for macOS build $MARKETING_VERSION ($BUILD_NUMBER) in App Store Connect"
  exit 1
fi

echo "==> Updating TestFlight notes for macOS build id $BUILD_ID"

JWT_TOKEN="$(create_jwt_token)"
LOCALIZATION_RESPONSE_FILE="$(mktemp)"
LOCALIZATION_ENDPOINT="/v1/betaBuildLocalizations?filter[build]=$(urlencode "$BUILD_ID")&filter[locale]=$(urlencode "$NOTES_LOCALE")&limit=1"
LOCALIZATION_STATUS_CODE="$(asc_request "$JWT_TOKEN" "GET" "$LOCALIZATION_ENDPOINT" "$LOCALIZATION_RESPONSE_FILE")"

if (( LOCALIZATION_STATUS_CODE < 200 || LOCALIZATION_STATUS_CODE >= 300 )); then
  echo "error: failed to fetch beta build localizations (HTTP $LOCALIZATION_STATUS_CODE)"
  extract_api_error "$LOCALIZATION_RESPONSE_FILE"
  rm -f "$LOCALIZATION_RESPONSE_FILE"
  exit 1
fi

LOCALIZATION_ID="$(
  /usr/bin/python3 - "$LOCALIZATION_RESPONSE_FILE" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
data = payload.get("data") or []
if data:
    print(data[0].get("id", ""))
PY
)"
rm -f "$LOCALIZATION_RESPONSE_FILE"

if [[ -n "$LOCALIZATION_ID" ]]; then
  UPDATE_BODY="$(
    /usr/bin/python3 - "$LOCALIZATION_ID" "$RELEASE_NOTES_TEXT" <<'PY'
import json
import sys

payload = {
    "data": {
        "type": "betaBuildLocalizations",
        "id": sys.argv[1],
        "attributes": {
            "whatsNew": sys.argv[2],
        },
    }
}
print(json.dumps(payload))
PY
  )"

  UPDATE_RESPONSE_FILE="$(mktemp)"
  JWT_TOKEN="$(create_jwt_token)"
  UPDATE_STATUS_CODE="$(asc_request "$JWT_TOKEN" "PATCH" "/v1/betaBuildLocalizations/$LOCALIZATION_ID" "$UPDATE_RESPONSE_FILE" "$UPDATE_BODY")"
  if (( UPDATE_STATUS_CODE < 200 || UPDATE_STATUS_CODE >= 300 )); then
    echo "error: failed to update existing TestFlight notes (HTTP $UPDATE_STATUS_CODE)"
    extract_api_error "$UPDATE_RESPONSE_FILE"
    rm -f "$UPDATE_RESPONSE_FILE"
    exit 1
  fi
  rm -f "$UPDATE_RESPONSE_FILE"
else
  CREATE_BODY="$(
    /usr/bin/python3 - "$BUILD_ID" "$NOTES_LOCALE" "$RELEASE_NOTES_TEXT" <<'PY'
import json
import sys

payload = {
    "data": {
        "type": "betaBuildLocalizations",
        "attributes": {
            "locale": sys.argv[2],
            "whatsNew": sys.argv[3],
        },
        "relationships": {
            "build": {
                "data": {
                    "type": "builds",
                    "id": sys.argv[1],
                }
            }
        },
    }
}
print(json.dumps(payload))
PY
  )"

  CREATE_RESPONSE_FILE="$(mktemp)"
  JWT_TOKEN="$(create_jwt_token)"
  CREATE_STATUS_CODE="$(asc_request "$JWT_TOKEN" "POST" "/v1/betaBuildLocalizations" "$CREATE_RESPONSE_FILE" "$CREATE_BODY")"
  if (( CREATE_STATUS_CODE < 200 || CREATE_STATUS_CODE >= 300 )); then
    echo "error: failed to create TestFlight notes localization (HTTP $CREATE_STATUS_CODE)"
    extract_api_error "$CREATE_RESPONSE_FILE"
    rm -f "$CREATE_RESPONSE_FILE"
    exit 1
  fi
  rm -f "$CREATE_RESPONSE_FILE"
fi

echo "==> TestFlight release notes updated for macOS"
