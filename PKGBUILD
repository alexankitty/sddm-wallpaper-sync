# Maintainer: You <you@example.com>
pkgname=sddm-wallpaper-sync
pkgver=1.0.0
pkgrel=1
pkgdesc="Sync the active user's wallpaper into the SDDM greeter theme"
arch=('any')
url="https://example.com/sddm-wallpaper-sync"
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
    "sddm-wallpaper-sync.sh"
    "sddm-wallpaper-sync.service"
    "sddm-wallpaper-sync.timer"
)
sha256sums=('SKIP'
            'SKIP'
            'SKIP')

package() {
    install -Dm755 "$srcdir/sddm-wallpaper-sync.sh" \
        "$pkgdir/usr/bin/sddm-wallpaper-sync"

    install -Dm644 "$srcdir/sddm-wallpaper-sync.service" \
        "$pkgdir/usr/lib/systemd/system/sddm-wallpaper-sync.service"

    install -Dm644 "$srcdir/sddm-wallpaper-sync.timer" \
        "$pkgdir/usr/lib/systemd/system/sddm-wallpaper-sync.timer"
}
