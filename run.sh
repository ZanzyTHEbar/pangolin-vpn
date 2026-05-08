#!/usr/bin/env bash
# Install the rootful Quadlet files for this repo into the system Podman path,
# then start or restart the Pangolin client service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
IMAGE="ghcr.io/zanzythebar/pangolin-client-container:latest"
SYSTEM_QUADLET_DIR="/etc/containers/systemd"
SYSTEM_ENV_DIR="/etc/pangolin-client"
SYSTEM_ENV_FILE="$SYSTEM_ENV_DIR/pangolin-client.env"
SYSTEM_BIN_DIR="/usr/local/bin"
SYSTEM_DNS_HELPER="$SYSTEM_BIN_DIR/pangolin-client-dns"
USER_QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

fail() {
  echo "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

cleanup_old_user_quadlets() {
  local file
  local quadlet_path
  local expected_path
  local removed=0
  local repo_owned_quadlets=0

  if [[ ! -d "$USER_QUADLET_DIR" ]]; then
    return 0
  fi

  for file in pangolin-client.container pangolin-client-config.volume pangolin-client-etc.volume; do
    quadlet_path="$USER_QUADLET_DIR/$file"
    expected_path="$SCRIPT_DIR/quadlet/$file"

    if [[ -L "$quadlet_path" ]] && [[ "$(readlink -f "$quadlet_path" 2>/dev/null || true)" == "$expected_path" ]]; then
      repo_owned_quadlets=1
      rm -f "$quadlet_path"
      removed=1
    fi
  done

  if (( repo_owned_quadlets )) && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user stop pangolin-client.service >/dev/null 2>&1 || true
  fi

  if (( removed )) && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    echo "Removed old rootless user Quadlet symlinks for pangolin-client."
  fi
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

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
  echo "No .env found. Copied .env.example to .env."
  echo "Run ./login.sh first, then rerun this script."
  exit 1
fi

require_command sudo
require_command podman
require_command systemctl
require_command install
require_command resolvectl
[[ -c /dev/net/tun ]] || fail "/dev/net/tun is not available on this host."

if [[ ! -r "$ENV_FILE" ]]; then
  fail "Cannot read $ENV_FILE"
fi

PANGOLIN_ENDPOINT="$(get_env_value PANGOLIN_ENDPOINT)"
PANGOLIN_CLIENT_ID="$(get_env_value PANGOLIN_CLIENT_ID)"
PANGOLIN_CLIENT_SECRET="$(get_env_value PANGOLIN_CLIENT_SECRET)"

if [[ -z "${PANGOLIN_ENDPOINT:-}" ]]; then
  echo "PANGOLIN_ENDPOINT is not set in .env. Set it and try again."
  exit 1
fi

if [[ -n "${PANGOLIN_CLIENT_ID:-}" || -n "${PANGOLIN_CLIENT_SECRET:-}" ]]; then
  if [[ -z "${PANGOLIN_CLIENT_ID:-}" || -z "${PANGOLIN_CLIENT_SECRET:-}" ]]; then
    fail "Set both PANGOLIN_CLIENT_ID and PANGOLIN_CLIENT_SECRET, or leave both empty."
  fi
fi

sudo -v

if ! sudo podman volume inspect pangolin-client-config >/dev/null 2>&1 || ! sudo podman volume inspect pangolin-client-etc >/dev/null 2>&1; then
  fail "Rootful Pangolin volumes do not exist yet. Run ./login.sh first."
fi

cleanup_old_user_quadlets

sudo install -d -m 0755 "$SYSTEM_QUADLET_DIR"
sudo install -d -m 0755 "$SYSTEM_ENV_DIR"
sudo install -d -m 0755 "$SYSTEM_BIN_DIR"
sudo install -m 0644 "$SCRIPT_DIR/quadlet/pangolin-client.container" "$SYSTEM_QUADLET_DIR/pangolin-client.container"
sudo install -m 0644 "$SCRIPT_DIR/quadlet/pangolin-client-config.volume" "$SYSTEM_QUADLET_DIR/pangolin-client-config.volume"
sudo install -m 0644 "$SCRIPT_DIR/quadlet/pangolin-client-etc.volume" "$SYSTEM_QUADLET_DIR/pangolin-client-etc.volume"
sudo install -m 0755 "$SCRIPT_DIR/pangolin-dns.sh" "$SYSTEM_DNS_HELPER"
sudo install -m 0600 "$ENV_FILE" "$SYSTEM_ENV_FILE"

sudo podman pull "$IMAGE"
sudo systemctl daemon-reload

if ! sudo systemctl is-enabled --quiet pangolin-client.service; then
  sudo systemctl enable pangolin-client.service >/dev/null
fi

if sudo systemctl is-active --quiet pangolin-client.service; then
  sudo systemctl restart pangolin-client.service
else
  sudo systemctl start pangolin-client.service
fi

echo "Installed rootful Quadlet files into $SYSTEM_QUADLET_DIR"
echo "Installed Pangolin DNS helper into $SYSTEM_DNS_HELPER"
echo "Installed service environment file into $SYSTEM_ENV_FILE"
echo "Pangolin client started. Check status: sudo systemctl status pangolin-client.service"
echo "Logs: sudo journalctl -u pangolin-client.service -f"
