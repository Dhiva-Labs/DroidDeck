#!/usr/bin/env bash
# Builds droiddeck_<version>_<arch>.deb from the Linux release bundle, for the
# architecture of the machine it runs on (amd64 or arm64).
#
# Run from the repo root after `flutter build linux --release`:
#
#     packaging/build_deb.sh [output-dir]        # default output-dir: dist/
#
# Needs the app icons already generated (python3 tool/make_icon.py —
# assets/icon/droiddeck_<size>.png) and dpkg-deb. Mirrors the layout used by
# other Dhiva Labs Linux .debs (see ~/dhiva-labs/dose_drop/tools/build_deb.sh):
# an /usr/lib/<pkg> install prefix, a thin /usr/bin wrapper, and standard
# hicolor icon + .desktop registration.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
DEB_ARCH="$(dpkg --print-architecture)"
case "$DEB_ARCH" in
  amd64) FLUTTER_ARCH=x64 ;;
  arm64) FLUTTER_ARCH=arm64 ;;
  *)
    echo "error: unsupported architecture '$DEB_ARCH' (amd64 or arm64)" >&2
    exit 1
    ;;
esac
BUNDLE="build/linux/$FLUTTER_ARCH/release/bundle"
ICON_DIR=assets/icon
ICON_SIZES="16 32 48 64 128 256 512"
VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"

[ -x "$BUNDLE/droid_deck" ] || {
  echo "error: $BUNDLE/droid_deck not found — run 'flutter build linux --release' first" >&2
  exit 1
}

for size in $ICON_SIZES; do
  [ -f "$ICON_DIR/droiddeck_${size}.png" ] || {
    echo "error: $ICON_DIR/droiddeck_${size}.png missing — run 'python3 tool/make_icon.py' first" >&2
    exit 1
  }
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/droiddeck"

mkdir -p \
  "$PKG/DEBIAN" \
  "$PKG/usr/lib/droiddeck" \
  "$PKG/usr/bin" \
  "$PKG/usr/share/applications" \
  "$PKG/usr/share/doc/droiddeck"
for size in $ICON_SIZES; do
  mkdir -p "$PKG/usr/share/icons/hicolor/${size}x${size}/apps"
done

cp -r "$BUNDLE/." "$PKG/usr/lib/droiddeck/"

cat > "$PKG/usr/bin/droiddeck" <<'EOF'
#!/bin/sh
exec /usr/lib/droiddeck/droid_deck "$@"
EOF
chmod 0755 "$PKG/usr/bin/droiddeck"

# Named after the GTK application id, which is also the window class, so
# GNOME Shell matches the running window to this launcher (and its icon).
# debian/ installs the same file for the PPA package.
install -m 0644 debian/com.dhivalabs.droid_deck.desktop \
  "$PKG/usr/share/applications/com.dhivalabs.droid_deck.desktop"

for size in $ICON_SIZES; do
  cp "$ICON_DIR/droiddeck_${size}.png" \
     "$PKG/usr/share/icons/hicolor/${size}x${size}/apps/droiddeck.png"
done

cat > "$PKG/usr/share/doc/droiddeck/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: droiddeck
Source: https://github.com/Dhiva-Labs/DroidDeck

Files: *
Copyright: $(date +%Y) Dhiva Labs
License: MIT
 See the LICENSE file at the project root (or
 https://opensource.org/license/mit) for the full license text.
EOF

INSTALLED_SIZE="$(du -sk "$PKG/usr" | cut -f1)"
cat > "$PKG/DEBIAN/control" <<EOF
Package: droiddeck
Version: ${VERSION}
Section: devel
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: Dhiva Labs <dhivakar101010@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: libgtk-3-0t64 | libgtk-3-0
Recommends: adb | android-sdk-platform-tools, scrcpy
Homepage: https://github.com/Dhiva-Labs/DroidDeck
Description: ADB command center for Android development
 DroidDeck is a Linux desktop GUI around adb and scrcpy: a live device
 dashboard with socket-based tracking, a logcat viewer with ring-buffered
 priority/tag/text/package filtering, an app manager (install, launch,
 force-stop, uninstall, base+split APK extract), a device file explorer with
 drag-and-drop push/pull, screenshot/recording/scrcpy screen tools, wireless
 adb pairing with saved devices, and a real interactive shell with a
 quick-actions grid.
EOF

# Normalize permissions — mkdir -p/cp inherit the caller's umask, which
# otherwise leaves group-writable dirs/files (lintian: non-standard-*-perm).
# Only the wrapper and the real binary need the executable bit back; every
# .so in the bundle ships non-executable already (dlopen'd, not exec'd).
find "$PKG" -type d -exec chmod 0755 {} +
find "$PKG" -type f -exec chmod 0644 {} +
chmod 0755 "$PKG/usr/bin/droiddeck" "$PKG/usr/lib/droiddeck/droid_deck"

mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/droiddeck_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
echo "built $DEB"
