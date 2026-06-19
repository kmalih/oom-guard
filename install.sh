#!/usr/bin/env bash
# Install oom-guard as a per-user systemd timer (no root needed).
#
#   PROC_PATTERN=my-worker ./install.sh
#
# Re-run any time to update the files; it re-enables the timer.
set -euo pipefail

PROC_PATTERN="${PROC_PATTERN:-claude.exe}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

mkdir -p "$BIN_DIR" "$UNIT_DIR"

install -m 0755 "$SRC/oom-guard.sh" "$BIN_DIR/oom-guard.sh"
install -m 0644 "$SRC/oom-guard.service" "$UNIT_DIR/oom-guard.service"
install -m 0644 "$SRC/oom-guard.timer"   "$UNIT_DIR/oom-guard.timer"

# Bake the chosen worker name into the service so the timer uses it.
if ! grep -q '^Environment=PROC_PATTERN=' "$UNIT_DIR/oom-guard.service"; then
  sed -i "/^\[Service\]/a Environment=PROC_PATTERN=$PROC_PATTERN" "$UNIT_DIR/oom-guard.service"
fi

systemctl --user daemon-reload
systemctl --user enable --now oom-guard.timer

echo "oom-guard installed. Watching process: $PROC_PATTERN"
echo "Status:  systemctl --user status oom-guard.timer"
echo "Logs:    cat ~/.local/state/oom-guard/oom-guard.log"
echo "Dry run: DRY_RUN=1 MEM_MIN_KB=999999999 PROC_PATTERN=$PROC_PATTERN ~/.local/bin/oom-guard.sh"
