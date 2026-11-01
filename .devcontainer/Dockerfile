FROM docker.io/library/archlinux:base-devel

RUN pacman -Syu --noconfirm --needed \
        qt6-declarative qt6-5compat quickshell mpv git cmake shellcheck \
    && useradd --create-home builder \
    && for package in qt6-mpvqml qt6-niriqml; do \
        install -d -o builder -g builder "/var/tmp/$package" \
        && curl --fail --location --retry 3 --max-time 120 \
            "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$package" \
            -o "/var/tmp/$package/PKGBUILD" \
        && chown builder:builder "/var/tmp/$package/PKGBUILD" \
        && runuser -u builder -- bash -c 'set -euo pipefail; cd "$1"; source PKGBUILD; test "$(vercmp "$pkgver" 0.2.0)" -ge 0; MAKEFLAGS=-j2 CMAKE_BUILD_PARALLEL_LEVEL=2 makepkg --noconfirm --cleanbuild' -- "/var/tmp/$package" \
        && pacman -U --noconfirm /var/tmp/"$package"/"$package"-[0-9]*.pkg.tar.zst \
        && rm -rf "/var/tmp/$package" || exit 1; \
    done \
    && pacman -Scc --noconfirm \
    && rm -rf /home/builder/.cache

WORKDIR /workspace
