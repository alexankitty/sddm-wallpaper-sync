# Maintainer: You <you@example.com>
pkgname=sync-wallpaper-to-sddm
pkgver=1.0.0
pkgrel=1
pkgdesc="Sync the active user's wallpaper into the SDDM greeter theme"
arch=('any')
url="https://example.com/sync-wallpaper-to-sddm"
license=('MIT')
depends=('systemd' 'util-linux')
optdepends=(
    'sddm: the greeter this syncs the wallpaper into'
    'swaybg: wallpaper daemon support'
    'swww: wallpaper daemon support (swww-daemon)'
    'awww: wallpaper daemon support (awww-daemon, the swww rename)'
    'hyprpaper: wallpaper daemon support'
    'wpaperd: wallpaper daemon support'
    'nitrogen: wallpaper daemon support'
    'feh: wallpaper daemon support'
    'xwallpaper: wallpaper daemon support'
    'variety: wallpaper daemon support'
)
backup=()
source=(
    "sync-wallpaper-to-sddm.sh"
    "sync-wallpaper-to-sddm.service"
    "sync-wallpaper-to-sddm.timer"
)
sha256sums=('SKIP'
            'SKIP'
            'SKIP')

package() {
    install -Dm755 "$srcdir/sync-wallpaper-to-sddm.sh" \
        "$pkgdir/usr/bin/sync-wallpaper-to-sddm"

    install -Dm644 "$srcdir/sync-wallpaper-to-sddm.service" \
        "$pkgdir/usr/lib/systemd/system/sync-wallpaper-to-sddm.service"

    install -Dm644 "$srcdir/sync-wallpaper-to-sddm.timer" \
        "$pkgdir/usr/lib/systemd/system/sync-wallpaper-to-sddm.timer"
}
