#!/usr/bin/env bash
# Builds the OpenJDK Mobile "Zero" VM (interpreter only, no JIT) for iOS devices or
# the simulator on Apple Silicon:
#
#   build_openjdk.sh sim|device
#
# Everything is pinned to the device runtime published by Mangatan
# (release embedded-openjdk-ios13-v16): same openjdk/mobile commit, same three
# patches, same ios-tools symbol keeper and libffi. That lets the VM reuse that
# release's java.base class image (lib/modules), which must come from the exact
# commit the VM was built from.
#
# Output: $WORK/out (sim) or $WORK/out-device, each {lib/*.a, include/}  (consumed by package_openjdk.sh)
set -euo pipefail

PLATFORM="${1:-sim}"
PKG="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-$PKG/.build/openjdk-ios}"
# Boot JDK 25-27 is accepted. OpenJDK's configure rejects paths with spaces,
# so Android Studio's bundled JBR 25 is copied somewhere without one.
BOOT_JDK="${BOOT_JDK:-$WORK/boot-jdk}"
STUDIO_JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
if [ ! -x "$BOOT_JDK/bin/javac" ]; then
  mkdir -p "$WORK"
  ditto "$STUDIO_JBR" "$BOOT_JDK"
fi
MIN_IOS="${MIN_IOS:-15.0}"

# The simulator keeps the paths it was first built with, so its configuration still applies.
case "$PLATFORM" in
  sim)
    CONF=iossim-aarch64-zero-release SDK=iphonesimulator TARGET="arm64-apple-ios${MIN_IOS}-simulator"
    LIBFFI=libffi-ios-sim.zip LIBFFI_SHA=701b522e3eff0263f18d4a9e487f0a7ac30050fb2af20e86b6849daa14f5781f
    SUPPORT="$WORK/support" OUT="$WORK/out"
    ;;
  device)
    CONF=ios-aarch64-zero-release SDK=iphoneos TARGET="arm64-apple-ios${MIN_IOS}"
    LIBFFI=libffi-ios.zip LIBFFI_SHA=4f39fd1d53fbd69d1bdbd915413077d130daa3f6792d1b3a03a690a9cbd4dea3
    SUPPORT="$WORK/support-device" OUT="$WORK/out-device"
    ;;
  *)
    echo "usage: $0 sim|device" >&2
    exit 2
    ;;
esac

MOBILE_COMMIT=fc10224720ee1c109b1207daeba8878822bb5363
IOS_TOOLS_COMMIT=f8524c91c012040e40e7f8af34e7a0f11af0da83
MANGATAN_COMMIT=8b516608909295b9f9fddc667a88a96c2ebf146c
PATCHES=(
  "8378080-zero-jni-env-lifetime.patch 34872a39326a5a56c019c8d2b5e6872eea09fe2a9f5e2a15fbea148c21930d59"
  "ios-libjava-global-symbols.patch 26859965c59907f36ac7b9102761fd7fd2f15a832e2c8ed7121842686fa6af1a"
  "ios-zero-runtime.patch 79000ed01a65f6a13457ad3162e1873428f900af65fa42ed493475f3b518415a"
)
LIBFFI_URL="https://github.com/openjdk-mobile/ios-tools/releases/download/libffi-build/$LIBFFI"

export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -d mobile/.git ]; then
  git init -q mobile
  git -C mobile remote add origin https://github.com/openjdk/mobile.git
  git -C mobile fetch -q --depth 1 origin "$MOBILE_COMMIT"
  git -C mobile -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  mkdir -p patches
  for entry in "${PATCHES[@]}"; do
    read -r name sha <<<"$entry"
    curl -sfL -o "patches/$name" \
      "https://raw.githubusercontent.com/1Selxo/Mangatan/$MANGATAN_COMMIT/tool/openjdk/$name"
    echo "$sha  patches/$name" | shasum -a 256 -c -
    git -C mobile apply "../patches/$name"
  done
  # Ours: commit the code cache read-write. Apple Silicon (simulator included) rejects
  # writable+executable pages outside MAP_JIT, and Zero never executes generated code.
  git -C mobile apply "$PKG/tool/ios/cs3-ios-zero-rw-code-cache.patch"
  curl -sfL -o mobile/src/hotspot/os/bsd/symbol_keeper.cpp \
    "https://raw.githubusercontent.com/openjdk-mobile/ios-tools/$IOS_TOOLS_COMMIT/openjdk-ext/src/hotspot/symbol_keeper.cpp"
fi

if [ ! -f "$SUPPORT/libffi.a" ]; then
  [ -f "$LIBFFI" ] || curl -sfL -o "$LIBFFI" "$LIBFFI_URL"
  echo "$LIBFFI_SHA  $LIBFFI" | shasum -a 256 -c -
  mkdir -p "$SUPPORT" && unzip -qo "$LIBFFI" -d "$SUPPORT"
fi

cd mobile
if [ ! -f "build/$CONF/spec.gmk" ]; then
  target_flags="-target $TARGET"
  bash configure \
    --with-conf-name="$CONF" \
    --disable-warnings-as-errors \
    --openjdk-target=aarch64-macos-ios \
    --with-boot-jdk="$BOOT_JDK" \
    --with-sysroot="$(xcrun --sdk "$SDK" --show-sdk-path)" \
    --with-libffi-include="$SUPPORT/include/ffi" \
    --with-libffi-lib="$SUPPORT" \
    --with-cups-include="$(xcrun --sdk macosx --show-sdk-path)/usr/include" \
    --with-extra-cflags="$target_flags" \
    --with-extra-cxxflags="$target_flags" \
    --with-extra-ldflags="$target_flags"
fi
# jdk.unsupported (sun.misc.Unsafe, which Gson needs) has no native code, so the static
# image leaves it out; package_openjdk.sh puts its classes on the boot class path.
make LOG=warn CONF="$CONF" static-libs-image jdk.unsupported-java

rm -rf "$OUT" && mkdir -p "$OUT/lib"
build="build/$CONF"
cp "$build/images/static-libs/lib/zero/libjvm.a" "$OUT/lib/"
cp "$build/images/static-libs/lib/"lib{java,jimage,net,nio,verify,zip}.a "$OUT/lib/"
cp "$SUPPORT/libffi.a" "$OUT/lib/"
cp -R "$build/jdk/include" "$OUT/include"
echo "OpenJDK $PLATFORM static libs ready in $OUT"
