#!/usr/bin/env bash
# Packs a Linux release bundle into an AppImage.
#
#   scripts/build_appimage.sh ARCH BUNDLE_DIR OUTPUT
#   scripts/build_appimage.sh x64 build/linux/x64/release/bundle skystream-linux-x64.AppImage
#
# ARCH is the bundle's, x64 or arm64. The AppImage runs where the bundle does:
# on that architecture, with a glibc at least as new as the build machine's
# (release.yml builds on Ubuntu 22.04, glibc 2.35). Like the .deb and the
# tarball it takes GTK 3, WebKitGTK 4.1, libsecret and VLC from the system,
# and its AppRun names whichever is missing.
#
# appimagetool and the AppImage runtime are pinned releases, checked against
# their SHA-256 before use and kept in ~/.cache/skystream-appimage. To build
# with another appimagetool, set APPIMAGETOOL to its executable; the runtime
# stays the pinned one.
set -euo pipefail

APPIMAGETOOL_VERSION=1.9.1
RUNTIME_VERSION=20251108
declare -A APPIMAGETOOL_SHA256=(
  [x86_64]=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
  [aarch64]=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
)
declare -A RUNTIME_SHA256=(
  [x86_64]=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
  [aarch64]=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444
)

# The application ID: the binary's GApplication ID (linux/CMakeLists.txt),
# which Wayland compositors report as the window's app ID. The desktop file,
# the icon and the AppStream entry are named after it, so the window gets the
# launcher's name and icon.
APP_ID=dev.akash.skystream

die() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -eq 3 ]] || die "usage: $0 ARCH BUNDLE_DIR OUTPUT"
case "$1" in
  x64) arch=x86_64 ;;
  arm64) arch=aarch64 ;;
  *) die "ARCH must be x64 or arm64, not '$1'" ;;
esac
bundle="$2"
output="$(realpath -m "$3")"
[[ -x "$bundle/skystream" ]] || die "no skystream binary in '$bundle'; run 'flutter build linux --release' first"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packaging="$root/linux/packaging/appimage"
icons="$root/macos/Runner/Assets.xcassets/AppIcon.appiconset"
version="$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' "$root/pubspec.yaml")"
[[ -n "$version" ]] || die "no version in pubspec.yaml"
# The release date AppStream shows: the commit's, so a rebuild matches.
date="$(git -C "$root" log -1 --format=%cs 2>/dev/null || date -u +%F)"

cache="${XDG_CACHE_HOME:-$HOME/.cache}/skystream-appimage"

# Downloads URL to DEST unless DEST already has the SHA256.
fetch() {
  local url="$1" sha256="$2" dest="$3"
  if [[ -f "$dest" ]] && sha256sum --check --status <<<"$sha256  $dest"; then
    return
  fi
  mkdir -p "$(dirname "$dest")"
  echo "==> Downloading $url"
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest.part" "$url"
  if ! sha256sum --check --status <<<"$sha256  $dest.part"; then
    rm -f "$dest.part"
    die "$url does not match its pinned SHA-256"
  fi
  mv "$dest.part" "$dest"
}

runtime="$cache/runtime-$RUNTIME_VERSION-$arch"
fetch "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_VERSION/runtime-$arch" \
  "${RUNTIME_SHA256[$arch]}" "$runtime"

tool="${APPIMAGETOOL:-}"
if [[ -z "$tool" ]]; then
  host="$(uname -m)"
  [[ -n "${APPIMAGETOOL_SHA256[$host]:-}" ]] || die "no appimagetool for a $host machine; set APPIMAGETOOL"
  image="$cache/appimagetool-$APPIMAGETOOL_VERSION-$host.AppImage"
  fetch "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-$host.AppImage" \
    "${APPIMAGETOOL_SHA256[$host]}" "$image"
  # Unpacked rather than run, so the build machine needs no FUSE.
  unpacked="$image.d"
  if [[ ! -x "$unpacked/AppRun" ]]; then
    rm -rf "$unpacked" "$unpacked.part"
    mkdir -p "$unpacked.part"
    chmod +x "$image"
    (cd "$unpacked.part" && "$image" --appimage-extract >/dev/null)
    mv "$unpacked.part/squashfs-root" "$unpacked"
    rm -rf "$unpacked.part"
  fi
  tool="$unpacked/AppRun"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
appdir="$work/SkyStream.AppDir"

echo "==> Packing $bundle ($arch, SkyStream $version)"
mkdir -p "$appdir/opt/skystream"
cp -a "$bundle/." "$appdir/opt/skystream/"
install -m 755 "$packaging/AppRun" "$appdir/AppRun"
install -Dm 644 "$packaging/$APP_ID.desktop" "$appdir/usr/share/applications/$APP_ID.desktop"
ln -s "usr/share/applications/$APP_ID.desktop" "$appdir/$APP_ID.desktop"
for size in 32 64 128 256 512; do
  install -Dm 644 "$icons/app_icon_$size.png" "$appdir/usr/share/icons/hicolor/${size}x$size/apps/$APP_ID.png"
done
# The icon theme spec asks for 48x48 at least, a size the macOS set lacks.
install -Dm 644 "$packaging/$APP_ID-48.png" "$appdir/usr/share/icons/hicolor/48x48/apps/$APP_ID.png"
ln -s "usr/share/icons/hicolor/256x256/apps/$APP_ID.png" "$appdir/$APP_ID.png"
ln -s "$APP_ID.png" "$appdir/.DirIcon"
# appimagetool looks for the AppStream entry under its older .appdata.xml name.
mkdir -p "$appdir/usr/share/metainfo"
sed -e "s/@VERSION@/$version/" -e "s/@DATE@/$date/" "$packaging/$APP_ID.metainfo.xml" \
  >"$appdir/usr/share/metainfo/$APP_ID.appdata.xml"

mkdir -p "$(dirname "$output")"
rm -f "$output"
# ARCH because the bundle's TorrServer may be another architecture's binary.
ARCH="$arch" "$tool" --runtime-file "$runtime" "$appdir" "$output"
echo "==> $output ($(du -h "$output" | cut -f1)), sha256 $(sha256sum "$output" | cut -d' ' -f1)"
