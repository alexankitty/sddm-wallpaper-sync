# Sync wallpaper to SDDM greeter

Detects the active graphical session (via `loginctl`), figures out which
wallpaper daemon that user is running, resolves the wallpaper it's currently
showing, and copies it into the active SDDM theme so the login screen matches
your desktop background.

## Supported wallpaper daemons

- `swaybg` (reads `-i` from its command line)
- `swww` / `swww-daemon` (via `swww query`)
- `awww` / `awww-daemon` - the renamed fork of swww (via `awww query`)
- `hyprpaper` (`~/.config/hypr/hyprpaper.conf`)
- `wpaperd` (`~/.config/wpaperd/{wallpaper,config}.toml`)
- `nitrogen` (`~/.config/nitrogen/bg-saved.cfg`)
- `feh` (`~/.fehbg`)
- `xwallpaper` (command line)
- `variety` (`~/.config/variety/wallpaper.jpg` symlink)

`mpvpaper` and `azote` are stubbed but not implemented - the script will
exit with a clear error naming the daemon if it hits one of these, so you
can add a case for your setup.

## How it works
It parses your sddm config `sddm.conf` first and `sddm.conf.d/*` second, to determine what the active theme is.

Then it parses both the `Main.qml` and `metadata.desktop` to determine where the background needs to go and which config to add a `.user` config to. 

Once completed, it will override the wallpaper of sddm/sddm-lock depending on how the sddm theme is configured.


## Install

### Arch Linux (PKGBUILD)

Put `PKGBUILD`, `sddm-wallpaper-sync.sh`, `sddm-wallpaper-sync.service`,
and `sddm-wallpaper-sync.timer` in the same directory, then:

```bash
makepkg -si
```

This installs the script to `/usr/bin/sddm-wallpaper-sync` and the units
to `/usr/lib/systemd/system/`. Then just enable/start as below.

The `sha256sums` in the PKGBUILD are set to `SKIP` since the sources are
local files sitting next to the PKGBUILD, not a remote tarball. If you move
this into a proper AUR/repo package with a download URL, regenerate them
with `updpkgsums`.

### Manual (any distro) - using install.sh

Put `install.sh`, `sddm-wallpaper-sync.sh`, `sddm-wallpaper-sync.service`,
and `sddm-wallpaper-sync.timer` in the same directory, then:

```bash
sudo ./install.sh                 # install only
sudo ./install.sh --enable        # install + enable the periodic timer
sudo ./install.sh --start         # install + run a sync once, right now
sudo ./install.sh --enable --start
```

It copies the script to `/usr/bin/sddm-wallpaper-sync`, the units to
`/etc/systemd/system/`, and runs `systemctl daemon-reload`. To remove
everything it installed:

```bash
sudo ./install.sh --uninstall
```

This doesn't touch any theme background already synced or its `.orig`
backup - run `sudo sddm-wallpaper-sync restore` first if you want the
theme's original background back before uninstalling.

### Manual (any distro) - by hand

```bash
sudo cp sddm-wallpaper-sync.sh /usr/bin/sddm-wallpaper-sync
sudo chmod +x /usr/bin/sddm-wallpaper-sync

sudo cp sddm-wallpaper-sync.service /etc/systemd/system/
sudo cp sddm-wallpaper-sync.timer   /etc/systemd/system/   # optional

sudo systemctl daemon-reload
```

### Enable it (both methods)

```bash
# Run once by hand to sanity-check it:
sudo systemctl start sddm-wallpaper-sync.service
journalctl -u sddm-wallpaper-sync.service -e

# Optional: keep it synced automatically every ~10 min
sudo systemctl enable --now sddm-wallpaper-sync.timer
```

## Why a timer instead of an instant trigger

There's no single generic event across all these wallpaper daemons for
"wallpaper just changed" - some (`swaybg`) don't even have a config file,
they just take an argument at launch. The timer is the simplest thing
that works everywhere. If you only use one daemon, you can instead skip
the timer and just call:

```bash
systemctl start sddm-wallpaper-sync.service
```

directly from whatever keybind/script you use to change your wallpaper -
that gives you an instant update with no polling.

## Requirements

- `runuser` (from `util-linux`), `loginctl` (systemd-logind), `pgrep`, `getent`, `awk`, `sed`
- Root privileges to write into `/usr/share/sddm/themes/...`

## Contributing
Submit a PR or Issue with whatever problems need to be addressed. I've only tested with awww.
