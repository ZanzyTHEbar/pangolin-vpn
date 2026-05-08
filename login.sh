#!/usr/bin/env bash
# Log into Pangolin with rootless Podman, then copy the resulting auth/device
# state into the rootful volumes used by the system service on this host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
IMAGE="ghcr.io/zanzythebar/pangolin-client-container:latest"
CONFIG_VOLUME="pangolin-client-config"
ETC_VOLUME="pangolin-client-etc"
DEVICE_LOGIN_BASE_URL=""

fail() {
  echo "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

filter_login_output() {
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      'Press Enter to open '*" in your browser..."| \
      'Failed to open browser automatically'| \
      'Please manually visit: '*)
        continue
        ;;
    esac

    printf '%s\n' "$line"
  done
}

get_env_value() {
  local key="$1"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*)
        ;;
      "$key="*)
        printf '%s' "${line#*=}"
        return 0
        ;;
    esac
  done < "$ENV_FILE"

  return 0
}

spawn_detached() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 < /dev/null &
  else
    "$@" >/dev/null 2>&1 < /dev/null &
  fi
}

open_device_login_page() {
  echo "Open this URL in your browser: $DEVICE_LOGIN_BASE_URL"

  if command -v xdg-open >/dev/null 2>&1; then
    spawn_detached xdg-open "$DEVICE_LOGIN_BASE_URL"
    echo "Attempting to open Pangolin device login in your browser..."
    return 0
  fi

  if command -v gio >/dev/null 2>&1; then
    spawn_detached gio open "$DEVICE_LOGIN_BASE_URL"
    echo "Attempting to open Pangolin device login in your browser..."
    return 0
  fi

  echo "Automatic browser opening is unavailable on this host/session."
  return 0
}

ensure_volume_exists() {
  local volume="$1"
  shift
  local -a podman_cmd=("$@")

  if ! "${podman_cmd[@]}" volume inspect "$volume" >/dev/null 2>&1; then
    "${podman_cmd[@]}" volume create "$volume" >/dev/null
  fi
}

get_volume_mountpoint() {
  local volume="$1"
  shift
  local -a podman_cmd=("$@")

  "${podman_cmd[@]}" volume inspect "$volume" --format '{{.Mountpoint}}'
}

sync_volume_into_rootful_store() {
  local source_mount="$1"
  local dest_mount="$2"

  [[ -d "$source_mount" ]] || fail "Missing source volume mount: $source_mount"

  sudo install -d -m 0755 "$dest_mount"

  sudo rsync -a --chown=root:root "$source_mount/" "$dest_mount/"
}

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
  echo "No .env found. Copied .env.example to .env."
  echo "Review .env, then run this script again."
  exit 1
fi

require_command podman
require_command sudo
require_command rsync

if [[ $EUID -eq 0 ]]; then
  fail "Run login.sh as your normal user, not with sudo."
fi

if [[ ! -r "$ENV_FILE" ]]; then
  fail "Cannot read $ENV_FILE"
fi

PANGOLIN_ENDPOINT="$(get_env_value PANGOLIN_ENDPOINT)"
PANGOLIN_CLIENT_ID="$(get_env_value PANGOLIN_CLIENT_ID)"
PANGOLIN_CLIENT_SECRET="$(get_env_value PANGOLIN_CLIENT_SECRET)"
DEVICE_LOGIN_BASE_URL="${PANGOLIN_ENDPOINT%/}/auth/login/device"

if [[ -z "${PANGOLIN_ENDPOINT:-}" ]]; then
  fail "PANGOLIN_ENDPOINT is not set in .env. Set it and try again."
fi

if [[ -n "${PANGOLIN_CLIENT_ID:-}" || -n "${PANGOLIN_CLIENT_SECRET:-}" ]]; then
  if [[ -z "${PANGOLIN_CLIENT_ID:-}" || -z "${PANGOLIN_CLIENT_SECRET:-}" ]]; then
    fail "Set both PANGOLIN_CLIENT_ID and PANGOLIN_CLIENT_SECRET, or leave both empty."
  fi
fi

podman pull "$IMAGE"
ensure_volume_exists "$CONFIG_VOLUME" podman
ensure_volume_exists "$ETC_VOLUME" podman

echo "This host's rootful Pangolin login path hangs, so login uses rootless Podman."
echo "After the login succeeds, this script will sync the auth state into the rootful volumes used by the system service."
echo "Paste the one-time code into the browser page and complete the authorization in your browser."

open_device_login_page

set +e
podman run --rm \
  --env-file "$ENV_FILE" \
  -v "$CONFIG_VOLUME:/root/.config/pangolin" \
  -v "$ETC_VOLUME:/etc/pangolin" \
  "$IMAGE" login-plain 2>&1 | filter_login_output
login_status=${PIPESTATUS[0]}
set -e

if [[ $login_status -ne 0 ]]; then
  fail "Pangolin login did not complete successfully."
fi

sudo -v
ensure_volume_exists "$CONFIG_VOLUME" sudo podman
ensure_volume_exists "$ETC_VOLUME" sudo podman

rootless_config_mount="$(get_volume_mountpoint "$CONFIG_VOLUME" podman)"
rootless_etc_mount="$(get_volume_mountpoint "$ETC_VOLUME" podman)"
rootful_config_mount="$(get_volume_mountpoint "$CONFIG_VOLUME" sudo podman)"
rootful_etc_mount="$(get_volume_mountpoint "$ETC_VOLUME" sudo podman)"

if [[ "$rootless_config_mount" == "$rootful_config_mount" || "$rootless_etc_mount" == "$rootful_etc_mount" ]]; then
  fail "Rootless and rootful Pangolin volume mountpoints must differ. Run login.sh as your normal user, not root."
fi

sync_volume_into_rootful_store "$rootless_config_mount" "$rootful_config_mount"
sync_volume_into_rootful_store "$rootless_etc_mount" "$rootful_etc_mount"

echo "Synced Pangolin auth/device state into the rootful volumes used by the system service."
echo "You can now run ./run.sh to start or restart the rootful Pangolin service."
