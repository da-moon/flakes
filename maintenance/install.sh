#!/usr/bin/env bash
set -euo pipefail

readonly REPO="${FLAKES_REPO:-/home/ubuntu/sync/github/flakes}"
readonly UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
readonly SERVICE="flakes-maintenance.service"
readonly TIMER="flakes-maintenance.timer"

case "${1:-}" in
  --enable|"") ;;
  *)
    printf 'Usage: %s [--enable]\n' "$0" >&2
    exit 2
    ;;
esac

install -D -m 0644 "$REPO/maintenance/systemd/$SERVICE" "$UNIT_DIR/$SERVICE"
install -D -m 0644 "$REPO/maintenance/systemd/$TIMER" "$UNIT_DIR/$TIMER"
systemctl --user daemon-reload

case "${1:-}" in
  --enable)
    systemctl --user enable --now "$TIMER"
    ;;
  "")
    printf 'Installed %s and %s. Existing timer enablement was left unchanged.\n' "$SERVICE" "$TIMER"
    printf 'After a successful manual service run, enable it with: %s --enable\n' "$0"
    ;;
esac
