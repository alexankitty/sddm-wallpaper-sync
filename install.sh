#!/usr/bin/env bash
#
# install.sh
#
# Installs sddm-wallpaper-sync: copies the script to /usr/bin, the
# systemd units to /etc/systemd/system, and reloads systemd. Doesn't
# enable/start anything by default — pass --enable and/or --start if you
# want that done for you too.
#
# Usage:
#   sudo ./install.sh                 install only
#   sudo ./install.sh --enable        install + enable the timer at boot
#   sudo ./install.sh --start         install + run a sync once, right now
#   sudo ./install.sh --enable --start
#   sudo ./install.sh --uninstall     remove installed files/units
#   sudo ./install.sh -h | --help

set -uo pipefail

BIN_NAME="sddm-wallpaper-sync"
BIN_DEST="/usr/bin/${BIN_NAME}"
UNIT_DIR="/etc/systemd/system"
SERVICE_NAME="${BIN_NAME}.service"
TIMER_NAME="${BIN_NAME}.timer"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

log() { echo "[install] $*"; }
die() { echo "[install] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  sudo ./install.sh                 install only
  sudo ./install.sh --enable        install + enable the timer at boot
  sudo ./install.sh --start         install + run a sync once, right now
  sudo ./install.sh --enable --start
  sudo ./install.sh --uninstall     remove installed files/units
  sudo ./install.sh -h | --help
EOF
}

ENABLE=0
START=0
UNINSTALL=0

for arg in "$@"; do
    case "$arg" in
        --enable) ENABLE=1 ;;
        --start) START=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option '$arg'. Use -h for usage." ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    die "Must be run as root (e.g. sudo $0 ...)."
fi

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [[ "$UNINSTALL" -eq 1 ]]; then
    log "Stopping and disabling timer/service (if active)..."
    systemctl disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true

    log "Removing installed files..."
    rm -f "$BIN_DEST"
    rm -f "${UNIT_DIR}/${SERVICE_NAME}" "${UNIT_DIR}/${TIMER_NAME}"

    systemctl daemon-reload

    log "Uninstalled."
    log "Note: this does NOT touch any theme backgrounds already synced, or"
    log "the '<file>.orig' backups sitting next to them. Run"
    log "  sudo ${BIN_DEST} restore"
    log "before uninstalling if you want the original theme background(s) back."
    exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

for f in "${BIN_NAME}.sh" "$SERVICE_NAME" "$TIMER_NAME"; do
    [[ -f "${SCRIPT_DIR}/${f}" ]] || die "Expected file not found next to this script: ${SCRIPT_DIR}/${f}"
done

log "Installing ${BIN_DEST}..."
install -Dm755 "${SCRIPT_DIR}/${BIN_NAME}.sh" "$BIN_DEST"

log "Installing systemd units to ${UNIT_DIR}..."
install -Dm644 "${SCRIPT_DIR}/${SERVICE_NAME}" "${UNIT_DIR}/${SERVICE_NAME}"
install -Dm644 "${SCRIPT_DIR}/${TIMER_NAME}" "${UNIT_DIR}/${TIMER_NAME}"

log "Reloading systemd..."
systemctl daemon-reload

if [[ "$ENABLE" -eq 1 ]]; then
    log "Enabling ${TIMER_NAME} (periodic sync, starts at next boot too)..."
    systemctl enable --now "$TIMER_NAME"
fi

if [[ "$START" -eq 1 ]]; then
    log "Running a sync now..."
    if systemctl start "$SERVICE_NAME"; then
        log "Sync ran. Check output with: journalctl -u ${SERVICE_NAME} -e"
    else
        log "Sync failed. Check output with: journalctl -u ${SERVICE_NAME} -e"
    fi
fi

log "Done."
if [[ "$ENABLE" -eq 0 && "$START" -eq 0 ]]; then
    cat <<EOF

Installed but nothing enabled/started yet. Next steps:

  # Run once by hand to sanity-check it:
  sudo systemctl start ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -e

  # Keep it synced automatically (~every 10 min, see the .timer file):
  sudo systemctl enable --now ${TIMER_NAME}

  # Restore a theme's original background(s):
  sudo ${BIN_DEST} restore
EOF
fi
