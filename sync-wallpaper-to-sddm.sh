#!/usr/bin/env bash
#
# sync-wallpaper-to-sddm.sh
#
# Finds the currently active graphical session, figures out which wallpaper
# daemon that user is running, resolves the wallpaper image/config it is
# currently using, and copies it into the active SDDM theme so the greeter
# shows the same background.
#
# Must be run as root (systemd service handles this).

set -uo pipefail

LOG_TAG="sync-wallpaper-to-sddm"

log() {
    echo "[$LOG_TAG] $*"
    command -v logger >/dev/null 2>&1 && logger -t "$LOG_TAG" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (it writes into /usr/share/sddm and reads other users' sessions)."
fi

# ---------------------------------------------------------------------------
# 1. Find the active session and its user
# ---------------------------------------------------------------------------

SESSION_ID=""
while read -r sid _; do
    [[ -z "$sid" ]] && continue
    state=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
    class=$(loginctl show-session "$sid" -p Class --value 2>/dev/null)
    type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
    # Skip the greeter's own session (Class=greeter) and inactive sessions
    if [[ "$state" == "active" && "$class" == "user" ]]; then
        SESSION_ID="$sid"
        break
    fi
done < <(loginctl list-sessions --no-legend)

[[ -z "$SESSION_ID" ]] && die "No active user session found via loginctl."

SESSION_USER=$(loginctl show-session "$SESSION_ID" -p Name --value)
SESSION_TYPE=$(loginctl show-session "$SESSION_ID" -p Type --value)   # wayland / x11
USER_HOME=$(getent passwd "$SESSION_USER" | cut -d: -f6)
USER_UID=$(id -u "$SESSION_USER" 2>/dev/null)

[[ -z "$USER_HOME" || -z "$USER_UID" ]] && die "Could not resolve home/uid for user '$SESSION_USER'."

log "Active session: id=$SESSION_ID user=$SESSION_USER type=$SESSION_TYPE home=$USER_HOME"

XDG_RUNTIME_DIR="/run/user/${USER_UID}"
USER_DBUS_ADDR="unix:path=${XDG_RUNTIME_DIR}/bus"

run_as_user() {
    sudo -u "$SESSION_USER" \
        env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="$USER_DBUS_ADDR" \
            HOME="$USER_HOME" \
        "$@"
}

# ---------------------------------------------------------------------------
# 2. Detect which wallpaper daemon is running for that user
# ---------------------------------------------------------------------------

detect_daemon() {
    local candidates=(swaybg swww-daemon awww-daemon hyprpaper wpaperd nitrogen feh xwallpaper variety mpvpaper azote)
    local d
    for d in "${candidates[@]}"; do
        if pgrep -u "$SESSION_USER" -x "$d" >/dev/null 2>&1; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

DAEMON=$(detect_daemon) || die "No known wallpaper daemon found running for user '$SESSION_USER'."
log "Detected wallpaper daemon: $DAEMON"

WALLPAPER_PATH=""
SOURCE_CONFIG=""   # path to the daemon's config file, if any, for reference

case "$DAEMON" in
    swaybg)
        # swaybg takes its image on the command line: swaybg -i /path/to/img -m fill
        CMDLINE=$(pgrep -u "$SESSION_USER" -x swaybg -a | head -n1)
        WALLPAPER_PATH=$(echo "$CMDLINE" | grep -oP '(?<=-i )\S+' | head -n1)
        ;;
    swww-daemon|awww-daemon)
        # swww (and its rename, awww) expose current state via `<bin> query`.
        # Match the CLI binary name to whichever daemon is actually running.
        if [[ "$DAEMON" == "awww-daemon" ]]; then
            QUERY_BIN="awww"
        else
            QUERY_BIN="swww"
        fi
        QUERY_OUT=$(run_as_user "$QUERY_BIN" query 2>/dev/null)
        WALLPAPER_PATH=$(echo "$QUERY_OUT" | grep -oP "image:\s*\K\S+" | head -n1)
        ;;
    hyprpaper)
        SOURCE_CONFIG="${USER_HOME}/.config/hypr/hyprpaper.conf"
        if [[ -f "$SOURCE_CONFIG" ]]; then
            WALLPAPER_PATH=$(grep -E '^\s*wallpaper\s*=' "$SOURCE_CONFIG" | tail -n1 | sed -E 's/^\s*wallpaper\s*=\s*[^,]*,\s*//')
        fi
        ;;
    wpaperd)
        for cfgname in wallpaper.toml config.toml; do
            candidate="${USER_HOME}/.config/wpaperd/${cfgname}"
            if [[ -f "$candidate" ]]; then
                SOURCE_CONFIG="$candidate"
                WALLPAPER_PATH=$(grep -E '^\s*path\s*=' "$candidate" | tail -n1 | sed -E 's/^\s*path\s*=\s*"?//; s/"?\s*$//')
                break
            fi
        done
        ;;
    nitrogen)
        SOURCE_CONFIG="${USER_HOME}/.config/nitrogen/bg-saved.cfg"
        if [[ -f "$SOURCE_CONFIG" ]]; then
            WALLPAPER_PATH=$(grep -m1 '^file=' "$SOURCE_CONFIG" | cut -d= -f2-)
        fi
        ;;
    feh)
        SOURCE_CONFIG="${USER_HOME}/.fehbg"
        if [[ -f "$SOURCE_CONFIG" ]]; then
            WALLPAPER_PATH=$(grep -oP "(?<=')[^']+\.(jpg|jpeg|png|bmp|webp)(?=')" "$SOURCE_CONFIG" | head -n1)
        fi
        ;;
    xwallpaper)
        CMDLINE=$(pgrep -u "$SESSION_USER" -x xwallpaper -a | head -n1)
        WALLPAPER_PATH=$(echo "$CMDLINE" | grep -oP '(?<=--zoom |--stretch |--maximize |--tile )\S+' | head -n1)
        ;;
    variety)
        SOURCE_CONFIG="${USER_HOME}/.config/variety/wallpaper.jpg"
        if [[ -e "$SOURCE_CONFIG" ]]; then
            WALLPAPER_PATH=$(readlink -f "$SOURCE_CONFIG")
        fi
        ;;
    mpvpaper|azote)
        die "Wallpaper extraction for '$DAEMON' is not implemented yet. Add a case for it in this script."
        ;;
esac

[[ -z "$WALLPAPER_PATH" ]] && die "Could not resolve current wallpaper image path for daemon '$DAEMON'."
[[ -f "$WALLPAPER_PATH" ]] || die "Resolved wallpaper path does not exist on disk: $WALLPAPER_PATH"

log "Resolved wallpaper image: $WALLPAPER_PATH"
[[ -n "$SOURCE_CONFIG" ]] && log "Source config: $SOURCE_CONFIG"

# ---------------------------------------------------------------------------
# 3. Figure out the active SDDM theme
# ---------------------------------------------------------------------------

SDDM_THEME=""
for f in /etc/sddm.conf /etc/sddm.conf.d/*.conf; do
    [[ -f "$f" ]] || continue
    val=$(awk -F= '
        /^\[Theme\]/ {in_theme=1; next}
        /^\[/ {in_theme=0}
        in_theme && $1 ~ /^ *Current *$/ {gsub(/ /,"",$2); print $2}
    ' "$f")
    [[ -n "$val" ]] && SDDM_THEME="$val"
done

if [[ -z "$SDDM_THEME" ]]; then
    SDDM_THEME="breeze"
    log "No Current= theme found in sddm.conf(.d); falling back to '$SDDM_THEME'."
fi

THEME_DIR="/usr/share/sddm/themes/${SDDM_THEME}"
[[ -d "$THEME_DIR" ]] || die "SDDM theme directory not found: $THEME_DIR"

log "Active SDDM theme: $SDDM_THEME ($THEME_DIR)"

# ---------------------------------------------------------------------------
# 4. Copy the wallpaper (and source config, for reference) into the theme
# ---------------------------------------------------------------------------

SYNC_DIR="${THEME_DIR}/wallpaper-sync"
mkdir -p "$SYNC_DIR"

EXT="${WALLPAPER_PATH##*.}"
DEST_IMG="${SYNC_DIR}/background.${EXT}"

cp -f "$WALLPAPER_PATH" "$DEST_IMG" || die "Failed to copy wallpaper into $DEST_IMG"
chmod 644 "$DEST_IMG"
log "Copied wallpaper to $DEST_IMG"

if [[ -n "$SOURCE_CONFIG" && -f "$SOURCE_CONFIG" ]]; then
    cp -f "$SOURCE_CONFIG" "${SYNC_DIR}/source-$(basename "$SOURCE_CONFIG")"
    log "Copied source config for reference to ${SYNC_DIR}/source-$(basename "$SOURCE_CONFIG")"
fi

# ---------------------------------------------------------------------------
# 5. Point the theme at the new wallpaper via a theme.conf.user override
#    (most SDDM themes read theme.conf.user first and it won't be clobbered
#    by package updates to theme.conf)
# ---------------------------------------------------------------------------

OVERRIDE="${THEME_DIR}/theme.conf.user"

if [[ -f "$OVERRIDE" ]] && grep -q '^Background=' "$OVERRIDE" 2>/dev/null; then
    sed -i "s|^Background=.*|Background=${DEST_IMG}|" "$OVERRIDE"
else
    {
        echo "[General]"
        echo "Background=${DEST_IMG}"
    } >> "$OVERRIDE"
fi

log "Updated $OVERRIDE with Background=${DEST_IMG}"
log "Done."
