#!/usr/bin/env bash

find_app_store_env_file() {
  local root_dir="$1"
  local shared_env="/Volumes/DRIVE/DEV/gphil-flutter/app_store_keys/app_store.env"

  if [[ -n "${APP_STORE_ENV_FILE:-}" ]]; then
    printf '%s' "$APP_STORE_ENV_FILE"
    return
  fi

  if [[ -f "$root_dir/app_store_keys/app_store.env" ]]; then
    printf '%s' "$root_dir/app_store_keys/app_store.env"
    return
  fi

  if [[ -f "$shared_env" ]]; then
    printf '%s' "$shared_env"
    return
  fi

  printf '%s' "$root_dir/app_store_keys/app_store.env"
}

load_app_store_env() {
  local root_dir="$1"

  APP_STORE_ENV_FILE="$(find_app_store_env_file "$root_dir")"
  export APP_STORE_ENV_FILE

  if [[ -f "$APP_STORE_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$APP_STORE_ENV_FILE"
  fi
}

app_store_env_root() {
  local env_file="${APP_STORE_ENV_FILE:-}"
  if [[ -n "$env_file" ]]; then
    dirname "$(dirname "$env_file")"
  fi
}

normalize_api_key_path() {
  local root_dir="$1"
  local candidate="$2"
  local env_root

  if [[ -z "$candidate" ]]; then
    printf '%s' "$candidate"
    return
  fi

  if [[ -f "$candidate" ]]; then
    printf '%s' "$candidate"
    return
  fi

  env_root="$(app_store_env_root)"

  if [[ "$candidate" == /app_store_keys/* ]]; then
    if [[ -f "$root_dir$candidate" ]]; then
      printf '%s' "$root_dir$candidate"
      return
    fi
    if [[ -n "$env_root" && -f "$env_root$candidate" ]]; then
      printf '%s' "$env_root$candidate"
      return
    fi
  fi

  if [[ "$candidate" != /* ]]; then
    if [[ -f "$root_dir/$candidate" ]]; then
      printf '%s' "$root_dir/$candidate"
      return
    fi
    if [[ -n "$env_root" && -f "$env_root/$candidate" ]]; then
      printf '%s' "$env_root/$candidate"
      return
    fi
  fi

  printf '%s' "$candidate"
}

discover_app_store_api_key() {
  local root_dir="$1"
  local env_root

  API_KEY_ID="${APPSTORE_API_KEY_ID:-}"
  API_ISSUER_ID="${APPSTORE_API_ISSUER_ID:-}"
  API_KEY_PATH="${APPSTORE_API_KEY_PATH:-}"

  if [[ -z "$API_KEY_ID" && -z "$API_KEY_PATH" ]]; then
    local auto_key_count=0
    local auto_key=""
    env_root="$(app_store_env_root)"

    while IFS= read -r key; do
      auto_key="$key"
      auto_key_count=$((auto_key_count + 1))
    done < <(
      {
        find "$root_dir/app_store_keys" -maxdepth 1 -type f -name 'AuthKey_*.p8' 2>/dev/null || true
        if [[ -n "$env_root" && "$env_root" != "$root_dir" ]]; then
          find "$env_root/app_store_keys" -maxdepth 1 -type f -name 'AuthKey_*.p8' 2>/dev/null || true
        fi
      } | sort -u
    )

    if [[ "$auto_key_count" -eq 1 ]]; then
      API_KEY_PATH="$auto_key"
      API_KEY_ID="$(basename "$API_KEY_PATH")"
      API_KEY_ID="${API_KEY_ID#AuthKey_}"
      API_KEY_ID="${API_KEY_ID%.p8}"
    fi
  fi

  API_KEY_PATH="$(normalize_api_key_path "$root_dir" "$API_KEY_PATH")"

  export API_KEY_ID API_ISSUER_ID API_KEY_PATH
}

require_app_store_api_key() {
  : "${API_KEY_ID:?Set APPSTORE_API_KEY_ID in $APP_STORE_ENV_FILE or shell env}"
  : "${API_ISSUER_ID:?Set APPSTORE_API_ISSUER_ID in $APP_STORE_ENV_FILE or shell env}"

  if [[ -z "$API_KEY_PATH" ]]; then
    API_KEY_PATH="$(app_store_env_root)/app_store_keys/AuthKey_${API_KEY_ID}.p8"
  fi

  if [[ ! -f "$API_KEY_PATH" ]]; then
    echo "error: API key file not found at '$API_KEY_PATH'" >&2
    return 1
  fi
}

urlencode() {
  /usr/bin/python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

create_jwt_token() {
  /usr/bin/python3 - "$API_KEY_ID" "$API_ISSUER_ID" "$API_KEY_PATH" <<'PY'
import base64
import json
import os
import subprocess
import sys
import tempfile
import time

key_id, issuer_id, key_path = sys.argv[1:4]

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

now = int(time.time())
header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
payload = {
    "iss": issuer_id,
    "iat": now,
    "exp": now + 1200,
    "aud": "appstoreconnect-v1",
}
message = (
    b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
    + "."
    + b64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
).encode("ascii")

with tempfile.NamedTemporaryFile(delete=False) as message_file:
    message_file.write(message)
    message_path = message_file.name

signature_path = message_path + ".sig"
try:
    subprocess.check_call(
        ["openssl", "dgst", "-sha256", "-sign", key_path, "-out", signature_path, message_path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    signature = open(signature_path, "rb").read()
finally:
    for path in (message_path, signature_path):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass

index = 0
if signature[index] != 0x30:
    raise SystemExit("bad DER signature")
index += 1
length = signature[index]
index += 1
if length & 0x80:
    byte_count = length & 0x7F
    length = int.from_bytes(signature[index : index + byte_count], "big")
    index += byte_count

parts = []
for _ in range(2):
    if signature[index] != 0x02:
        raise SystemExit("bad DER integer")
    index += 1
    part_length = signature[index]
    index += 1
    value = signature[index : index + part_length]
    index += part_length
    parts.append(value.lstrip(b"\0").rjust(32, b"\0"))

print(message.decode("ascii") + "." + b64url(b"".join(parts)))
PY
}

asc_request() {
  local jwt_token="$1"
  local method="$2"
  local endpoint="$3"
  local response_file="$4"
  local request_body="${5:-}"

  if [[ -n "$request_body" ]]; then
    curl -sS \
      --globoff \
      -o "$response_file" \
      -w "%{http_code}" \
      -X "$method" \
      -H "Authorization: Bearer $jwt_token" \
      -H "Content-Type: application/json" \
      -d "$request_body" \
      "https://api.appstoreconnect.apple.com$endpoint"
  else
    curl -sS \
      --globoff \
      -o "$response_file" \
      -w "%{http_code}" \
      -X "$method" \
      -H "Authorization: Bearer $jwt_token" \
      "https://api.appstoreconnect.apple.com$endpoint"
  fi
}

extract_api_error() {
  local response_file="$1"
  /usr/bin/python3 - "$response_file" <<'PY'
import json
import sys

try:
    payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
    print("No structured API error response.")
    raise SystemExit(0)

errors = payload.get("errors") or []
if not errors:
    print("No structured API error response.")
    raise SystemExit(0)

error = errors[0]
detail = error.get("detail") or error.get("title") or ""
status = error.get("status") or ""
code = error.get("code") or ""
parts = [part for part in [f"status={status}" if status else "", f"code={code}" if code else "", detail] if part]
print(" | ".join(parts))
PY
}

app_store_app_id_for_bundle_id() {
  local bundle_id="$1"
  local jwt_token
  local response_file
  local status_code
  local endpoint

  require_app_store_api_key
  jwt_token="$(create_jwt_token)"
  response_file="$(mktemp)"
  endpoint="/v1/apps?filter[bundleId]=$(urlencode "$bundle_id")&limit=1"
  status_code="$(asc_request "$jwt_token" "GET" "$endpoint" "$response_file")"

  if (( status_code < 200 || status_code >= 300 )); then
    echo "error: failed to fetch App Store Connect app for bundle '$bundle_id' (HTTP $status_code)" >&2
    extract_api_error "$response_file" >&2
    rm -f "$response_file"
    return 1
  fi

  /usr/bin/python3 - "$response_file" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
data = payload.get("data") or []
if data:
    print(data[0].get("id", ""))
PY
  rm -f "$response_file"
}

latest_build_number_for_version() {
  local app_id="$1"
  local marketing_version="$2"
  local jwt_token
  local response_file
  local status_code
  local endpoint

  require_app_store_api_key
  jwt_token="$(create_jwt_token)"
  response_file="$(mktemp)"
  endpoint="/v1/builds?filter[app]=$(urlencode "$app_id")&limit=200&sort=-uploadedDate&include=preReleaseVersion"
  status_code="$(asc_request "$jwt_token" "GET" "$endpoint" "$response_file")"

  if (( status_code < 200 || status_code >= 300 )); then
    echo "error: failed to fetch App Store Connect builds (HTTP $status_code)" >&2
    extract_api_error "$response_file" >&2
    rm -f "$response_file"
    return 1
  fi

  /usr/bin/python3 - "$response_file" "$marketing_version" <<'PY'
import json
import re
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target_version = sys.argv[2]

included_versions = {}
for item in payload.get("included") or []:
    if item.get("type") == "preReleaseVersions":
        included_versions[item.get("id")] = (item.get("attributes") or {}).get("version")

numbers = []
for build in payload.get("data") or []:
    rel = ((build.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}
    version = included_versions.get(rel.get("id"))
    if target_version and version and version != target_version:
        continue
    raw = (build.get("attributes") or {}).get("version") or ""
    if re.fullmatch(r"[0-9]+", raw):
        numbers.append(int(raw))

print(max(numbers) if numbers else 0)
PY
  rm -f "$response_file"
}

