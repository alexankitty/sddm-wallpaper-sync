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

# Grab the daemon's own PID so we can read its *actual* environment below,
# rather than guessing WAYLAND_DISPLAY/DBUS_SESSION_BUS_ADDRESS/etc ourselves.
DAEMON_PID=$(pgrep -u "$SESSION_USER" -x "$DAEMON" | head -n1)
[[ -z "$DAEMON_PID" ]] && die "Detected daemon '$DAEMON' but could not get its PID."

# ---------------------------------------------------------------------------
# 2a. Recover the daemon's real environment from /proc/<pid>/environ
#
# This matters because things like `swww query` / `awww query` talk to a
# per-Wayland-session IPC socket, and need WAYLAND_DISPLAY (and sometimes
# XAUTHORITY/DISPLAY for X11) to find the right one. Reconstructing these
# by hand (e.g. always assuming "wayland-1") is fragile; reading them
# straight out of the daemon's own environment is exact, since it
# inherited them from the compositor/session at launch. Root can always
# read another process's environ.
# ---------------------------------------------------------------------------

get_pid_env() {
    local pid="$1" var="$2"
    tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null \
        | awk -F= -v k="$var" '$1==k { sub(/^[^=]*=/, ""); print; exit }'
}

ENV_WAYLAND_DISPLAY=$(get_pid_env "$DAEMON_PID" WAYLAND_DISPLAY)
ENV_DISPLAY=$(get_pid_env "$DAEMON_PID" DISPLAY)
ENV_XAUTHORITY=$(get_pid_env "$DAEMON_PID" XAUTHORITY)
ENV_XDG_RUNTIME_DIR=$(get_pid_env "$DAEMON_PID" XDG_RUNTIME_DIR)
ENV_DBUS_ADDR=$(get_pid_env "$DAEMON_PID" DBUS_SESSION_BUS_ADDRESS)

# Fall back to reasonable defaults only if the daemon's environ didn't have them
XDG_RUNTIME_DIR="${ENV_XDG_RUNTIME_DIR:-/run/user/${USER_UID}}"
DBUS_ADDR="${ENV_DBUS_ADDR:-unix:path=${XDG_RUNTIME_DIR}/bus}"

log "Recovered session env from PID $DAEMON_PID: WAYLAND_DISPLAY=${ENV_WAYLAND_DISPLAY:-<none>} DISPLAY=${ENV_DISPLAY:-<none>} XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"

EXTRA_ENV=(
    "HOME=${USER_HOME}"
    "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
    "DBUS_SESSION_BUS_ADDRESS=${DBUS_ADDR}"
)
[[ -n "$ENV_WAYLAND_DISPLAY" ]] && EXTRA_ENV+=("WAYLAND_DISPLAY=${ENV_WAYLAND_DISPLAY}")
[[ -n "$ENV_DISPLAY" ]] && EXTRA_ENV+=("DISPLAY=${ENV_DISPLAY}")
[[ -n "$ENV_XAUTHORITY" ]] && EXTRA_ENV+=("XAUTHORITY=${ENV_XAUTHORITY}")

# Using `runuser` instead of `sudo`: we're already root, so this needs no
# PAM password prompt and no TTY, which matters when running non-interactively
# from a systemd service (sudo can behave inconsistently there depending on
# the sudoers policy).
run_as_user() {
    runuser -u "$SESSION_USER" -- env "${EXTRA_ENV[@]}" "$@"
}

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
        QUERY_OUT=$(run_as_user "$QUERY_BIN" query 2>&1)
        WALLPAPER_PATH=$(echo "$QUERY_OUT" | grep -oP "image:\s*\K\S+" | head -n1)
        if [[ -z "$WALLPAPER_PATH" ]]; then
            log "'$QUERY_BIN query' produced no usable output: $QUERY_OUT"
        fi
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

get_theme_from_file() {
    awk -F= '
        /^\[Theme\]/ {in_theme=1; next}
        /^\[/ {in_theme=0}
        in_theme && $1 ~ /^ *Current *$/ {gsub(/ /,"",$2); print $2}
    ' "$1"
}

# /etc/sddm.conf is treated as authoritative: if it sets a theme, that wins
# outright. Only fall back to /etc/sddm.conf.d/*.conf snippets if the main
# config file doesn't set one.
if [[ -f /etc/sddm.conf ]]; then
    val=$(get_theme_from_file /etc/sddm.conf)
    if [[ -n "$val" ]]; then
        SDDM_THEME="$val"
        log "Theme resolved from /etc/sddm.conf: $SDDM_THEME"
    fi
fi

if [[ -z "$SDDM_THEME" ]]; then
    for f in /etc/sddm.conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        val=$(get_theme_from_file "$f")
        if [[ -n "$val" ]]; then
            SDDM_THEME="$val"
            log "Theme resolved from $f"
        fi
    done
fi

if [[ -z "$SDDM_THEME" ]]; then
    SDDM_THEME="breeze"
    log "No Current= theme found in sddm.conf(.d); falling back to '$SDDM_THEME'."
fi

THEME_DIR="/usr/share/sddm/themes/${SDDM_THEME}"
[[ -d "$THEME_DIR" ]] || die "SDDM theme directory not found: $THEME_DIR"

log "Active SDDM theme: $SDDM_THEME ($THEME_DIR)"

# ---------------------------------------------------------------------------
# 4. Copy the wallpaper (and source config, for reference) into the theme
#
# Some themes' QML (e.g. Silent) hardcode a "backgrounds/" prefix and
# concatenate it onto whatever the config's Background value is, rather
# than treating that value as a normal path: source: "backgrounds/" + value.
# Feeding those themes an absolute path breaks them, since
# "backgrounds/" + "/abs/path" is not a valid path and silently falls back
# to the theme's own default. Detect that convention by grepping the
# theme's QML for the literal concatenation, and adapt: store the file
# inside the theme's backgrounds/ dir and reference it with a bare
# filename instead of an absolute path.
# ---------------------------------------------------------------------------

EXT="${WALLPAPER_PATH##*.}"

RELATIVE_BG=false
if [[ -d "${THEME_DIR}/backgrounds" ]] && grep -qrE '"backgrounds/"[[:space:]]*\+' "${THEME_DIR}" --include='*.qml' 2>/dev/null; then
    RELATIVE_BG=true
fi

if [[ "$RELATIVE_BG" == true ]]; then
    SYNC_DIR="${THEME_DIR}/backgrounds"
    DEST_IMG="${SYNC_DIR}/wallpaper-sync.${EXT}"
    BG_VALUE="wallpaper-sync.${EXT}"   # relative to backgrounds/, per this theme's QML convention
    log "Theme resolves backgrounds as 'backgrounds/' + <value>; using relative filename '$BG_VALUE'"
else
    SYNC_DIR="${THEME_DIR}/wallpaper-sync"
    DEST_IMG="${SYNC_DIR}/background.${EXT}"
    BG_VALUE="$DEST_IMG"   # absolute path, the common convention
fi

mkdir -p "$SYNC_DIR"
cp -f "$WALLPAPER_PATH" "$DEST_IMG" || die "Failed to copy wallpaper into $DEST_IMG"
chmod 644 "$DEST_IMG"
log "Copied wallpaper to $DEST_IMG"

if [[ -n "$SOURCE_CONFIG" && -f "$SOURCE_CONFIG" ]]; then
    cp -f "$SOURCE_CONFIG" "${SYNC_DIR}/source-$(basename "$SOURCE_CONFIG")"
    log "Copied source config for reference to ${SYNC_DIR}/source-$(basename "$SOURCE_CONFIG")"
fi


# ---------------------------------------------------------------------------
# 5. Point the theme at the new wallpaper via a "<config>.user" override
#
# SDDM's QML config reader (the "explicitly typed API" -- see the
# ConfigFile comment in metadata.desktop) reads "<config>.user" alongside
# the base config and lets its values take precedence, section by section.
# This is the correct place to make this change: it never touches the
# theme's shipped config, so there's nothing to back up or restore, and it
# survives theme package updates. We only ever write the Background key
# itself, scoped to whichever section(s) the base config actually defines
# it under -- never a full copy of the config.
# ---------------------------------------------------------------------------

metadata_desktop_path="${THEME_DIR}/metadata.desktop"
conf_path="${THEME_DIR}/$(sed -n 's/^ConfigFile=\(.*\)/\1/p' < $metadata_desktop_path)"

[[ -f "$conf_path" ]] || die "SDDM theme config file not found: $conf_path"

USER_OVERRIDE="${conf_path}.user"

# Find every section in the base config that declares a Background/background
# key, in order of first appearance, deduplicated. Falls back to [General]
# if the theme uses a flat, non-sectioned Background key.
mapfile -t BG_SECTIONS < <(awk '
    /^[[:space:]]*\[/ {
        line=$0
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", line)
        section=line
        next
    }
    /^[[:space:]]*[Bb]ackground[[:space:]]*=/ {
        if (!(section in seen)) { print section; seen[section]=1 }
    }
' "$conf_path")

[[ "${#BG_SECTIONS[@]}" -eq 0 ]] && BG_SECTIONS=("General")

log "Sections with a Background key in $conf_path: ${BG_SECTIONS[*]}"

for section in "${BG_SECTIONS[@]}"; do
    if [[ -f "$USER_OVERRIDE" ]] && grep -qF "[${section}]" "$USER_OVERRIDE"; then
        # Section already exists in the override file: update/insert its
        # background line in place without touching anything else there.
        awk -v sec="[${section}]" -v val="$BG_VALUE" '
            BEGIN { in_sec=0; done=0 }
            /^\[/ {
                if (in_sec && !done) { print "background = \"" val "\""; done=1 }
                in_sec = ($0 == sec)
                print; next
            }
            in_sec && /^[[:space:]]*[Bb]ackground[[:space:]]*=/ {
                print "background = \"" val "\""; done=1; next
            }
            { print }
            END { if (in_sec && !done) print "background = \"" val "\"" }
        ' "$USER_OVERRIDE" > "${USER_OVERRIDE}.tmp" && mv "${USER_OVERRIDE}.tmp" "$USER_OVERRIDE"
    else
        {
            echo "[${section}]"
            echo "background = \"${BG_VALUE}\""
        } >> "$USER_OVERRIDE"
    fi
done

log "Updated $USER_OVERRIDE with background overrides for: ${BG_SECTIONS[*]} -> ${BG_VALUE}"
log "Done."
