# Sync wallpaper to SDDM greeter

Detects the active graphical session (via `loginctl`), figures out which
wallpaper daemon that user is running, resolves the wallpaper it's currently
showing, and copies it into the active SDDM theme so the login screen matches
your desktop background.

## Supported wallpaper daemons

- `swaybg` (reads `-i` from its command line)
- `swww` / `swww-daemon` (via `swww query`)
- `awww` / `awww-daemon` — the renamed fork of swww (via `awww query`)
- `hyprpaper` (`~/.config/hypr/hyprpaper.conf`)
- `wpaperd` (`~/.config/wpaperd/{wallpaper,config}.toml`)
- `nitrogen` (`~/.config/nitrogen/bg-saved.cfg`)
- `feh` (`~/.fehbg`)
- `xwallpaper` (command line)
- `variety` (`~/.config/variety/wallpaper.jpg` symlink)

`mpvpaper` and `azote` are stubbed but not implemented — the script will
exit with a clear error naming the daemon if it hits one of these, so you
can add a case for your setup.

## How it finds the SDDM theme

It reads `Current=` from `[Theme]` in `/etc/sddm.conf` and
`/etc/sddm.conf.d/*.conf` (falls back to `breeze` if none is set), then
writes into:

```
/usr/share/sddm/themes/<theme>/wallpaper-sync/background.<ext>
```

and points the theme at it via a `theme.conf.user` override (most SDDM
themes read this file and prefer it over the packaged `theme.conf`, so
package updates won't clobber your change):

```
[General]
Background=/usr/share/sddm/themes/<theme>/wallpaper-sync/background.<ext>
```

If your specific theme uses a different key than `Background=` for its
image (check the theme's `theme.conf`), edit the last section of the
script accordingly.

## Install

### Arch Linux (PKGBUILD)

Put `PKGBUILD`, `sync-wallpaper-to-sddm.sh`, `sync-wallpaper-to-sddm.service`,
and `sync-wallpaper-to-sddm.timer` in the same directory, then:

```bash
makepkg -si
```

This installs the script to `/usr/bin/sync-wallpaper-to-sddm` and the units
to `/usr/lib/systemd/system/`. Then just enable/start as below.

The `sha256sums` in the PKGBUILD are set to `SKIP` since the sources are
local files sitting next to the PKGBUILD, not a remote tarball. If you move
this into a proper AUR/repo package with a download URL, regenerate them
with `updpkgsums`.

### Manual (any distro)

```bash
sudo cp sync-wallpaper-to-sddm.sh /usr/bin/sync-wallpaper-to-sddm
sudo chmod +x /usr/bin/sync-wallpaper-to-sddm

sudo cp sync-wallpaper-to-sddm.service /etc/systemd/system/
sudo cp sync-wallpaper-to-sddm.timer   /etc/systemd/system/   # optional

sudo systemctl daemon-reload
```

### Enable it (both methods)

```bash
# Run once by hand to sanity-check it:
sudo systemctl start sync-wallpaper-to-sddm.service
journalctl -u sync-wallpaper-to-sddm.service -e

# Optional: keep it synced automatically every ~10 min
sudo systemctl enable --now sync-wallpaper-to-sddm.timer
```

## Why a timer instead of an instant trigger

There's no single generic event across all these wallpaper daemons for
"wallpaper just changed" — some (`swaybg`) don't even have a config file,
they just take an argument at launch. The timer is the simplest thing
that works everywhere. If you only use one daemon, you can instead skip
the timer and just call:

```bash
systemctl start sync-wallpaper-to-sddm.service
```

directly from whatever keybind/script you use to change your wallpaper —
that gives you an instant update with no polling.

## Requirements

- `sudo`, `loginctl` (systemd-logind), `pgrep`, `getent`, `awk`, `sed`
- Root privileges to write into `/usr/share/sddm/themes/...`
