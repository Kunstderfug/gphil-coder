#!/usr/bin/env bash

run_app_store_upload_with_retries() {
  local retry_delay="${APPSTORE_UPLOAD_RETRY_DELAY_SECONDS:-10}"
  local retry_timeout="${APPSTORE_UPLOAD_RETRY_TIMEOUT_SECONDS:-300}"

  if ! [[ "$retry_delay" =~ ^[0-9]+$ ]] || (( retry_delay <= 0 )); then
    echo "error: APPSTORE_UPLOAD_RETRY_DELAY_SECONDS must be a positive integer"
    return 2
  fi

  if ! [[ "$retry_timeout" =~ ^[0-9]+$ ]] || (( retry_timeout <= 0 )); then
    echo "error: APPSTORE_UPLOAD_RETRY_TIMEOUT_SECONDS must be a positive integer"
    return 2
  fi

  local started_at
  local attempt=1
  local exit_code=0
  started_at="$(date +%s)"

  while true; do
    echo "==> Upload attempt $attempt"
    if "$@"; then
      return 0
    fi

    exit_code=$?

    local now
    local elapsed
    local remaining
    local sleep_for
    now="$(date +%s)"
    elapsed=$((now - started_at))
    remaining=$((retry_timeout - elapsed))

    if (( remaining <= 0 )); then
      echo "error: upload failed after retrying for $retry_timeout seconds"
      return "$exit_code"
    fi

    sleep_for="$retry_delay"
    if (( sleep_for > remaining )); then
      sleep_for="$remaining"
    fi

    echo "warning: upload attempt $attempt failed with exit code $exit_code; retrying in $sleep_for seconds ($remaining seconds remaining)"
    sleep "$sleep_for"
    attempt=$((attempt + 1))
  done
}

