#!/usr/bin/env bash
# Configure systemd-resolved for Pangolin only while the rootful client service
# is active and the tunnel interface exists.

set -euo pipefail

CONTAINER_NAME="${PANGOLIN_CONTAINER_NAME:-pangolin-client}"
INTERFACE_NAME="${PANGOLIN_INTERFACE_NAME:-pangolin}"
DNS_SERVER="${PANGOLIN_HOST_DNS:-100.96.128.1}"
MAX_WAIT="${PANGOLIN_DNS_WAIT_SECONDS:-60}"
ROUTE_DOMAINS="${PANGOLIN_ROUTE_DOMAINS:-home.arpa}"

have_command() {
  command -v "$1" >/dev/null 2>&1
}

container_running() {
  podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx true
}

interface_ready() {
  ip link show "$INTERFACE_NAME" >/dev/null 2>&1
}

configured_route_domains() {
  local entry

  IFS=',' read -r -a raw_domains <<< "$ROUTE_DOMAINS"

  for entry in "${raw_domains[@]}"; do
    entry="${entry//[[:space:]]/}"
    [[ -z "$entry" ]] && continue

    if [[ "$entry" == ~* ]]; then
      printf '%s\n' "$entry"
    else
      printf '~%s\n' "$entry"
    fi
  done | sort -u
}

start() {
  local waited=0
  local -a domains=()

  while (( waited < MAX_WAIT )); do
    if container_running && interface_ready; then
      mapfile -t domains < <(configured_route_domains)

      if (( ${#domains[@]} > 0 )); then
        resolvectl dns "$INTERFACE_NAME" "$DNS_SERVER"
        resolvectl domain "$INTERFACE_NAME" "${domains[@]}"
        resolvectl default-route "$INTERFACE_NAME" no || true
        resolvectl flush-caches || true
        echo "Configured systemd-resolved on $INTERFACE_NAME with DNS $DNS_SERVER for domains: ${domains[*]}"
        return 0
      fi
    fi

    sleep 2
    (( waited += 2 )) || true
  done

  echo "Timed out waiting for Pangolin DNS readiness on $INTERFACE_NAME; leaving host DNS unchanged" >&2
  return 0
}

stop() {
  resolvectl revert "$INTERFACE_NAME" >/dev/null 2>&1 || true
  resolvectl flush-caches || true
  echo "Reverted systemd-resolved configuration for $INTERFACE_NAME"
}

case "${1:-}" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  *)
    echo "Usage: $0 start|stop" >&2
    exit 1
    ;;
esac
