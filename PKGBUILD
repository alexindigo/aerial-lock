pkgname=aerial-lock
pkgver=0.1.0
pkgrel=1
pkgdesc="Wayland session-lock client with Apple Aerial-style video backgrounds"
arch=('any')
url="https://github.com/aerial-lock/aerial-lock"
license=('GPL-3.0-or-later')
depends=('quickshell' 'pam')
makedepends=('gcc')
optdepends=(
    'qt6-mpvqml: video background support (Phase 2+)'
    'qt6-dbusqml: D-Bus integration (Phase 4+)'
)
source=()
sha256sums=()

build() {
    make
}

package() {
    make PREFIX=/usr DESTDIR="$pkgdir" install
}
