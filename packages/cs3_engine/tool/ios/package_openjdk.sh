#!/usr/bin/env bash
# Packages the VMs built by build_openjdk.sh as OpenJDKRuntime.xcframework, with a slice
# for each platform built: ios-arm64 (devices) and ios-arm64-simulator.
#
# Each framework is a dynamic library linked with -all_load, so every JNI entry
# point in the static class libraries stays exported and the VM can find it at
# run time. The VM derives java.home as <framework>/lib (os_bsd.cpp, static
# iOS builds), so the Java home lives there. It holds the java.base class image from the
# matching Mangatan release plus, for the boot class path, java.logging classes (OkHttp logs
# through it) and jdk.unsupported classes (Gson creates objects through sun.misc.Unsafe).
set -euo pipefail

PKG="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-$PKG/.build/openjdk-ios}"
DEST="${DEST:-$PKG/ios/Frameworks}"
MIN_IOS="${MIN_IOS:-15.0}"
BUNDLE_URL=https://github.com/1Selxo/Mangatan/releases/download/embedded-openjdk-ios13-v16/java_bundle-device.zip
BUNDLE_SHA=15369b9bb9dfdd400c18c56b30e2f6cf316b81d4e0bae5ddd6b1fe72355c4b0b
BOOT_JDK="$WORK/boot-jdk"
stage="$WORK/stage"
rm -rf "$stage" && mkdir -p "$stage"

if [ ! -f "$WORK/java_bundle-device.zip" ]; then
  curl -sfL -o "$WORK/java_bundle-device.zip" "$BUNDLE_URL"
fi
echo "$BUNDLE_SHA  $WORK/java_bundle-device.zip" | shasum -a 256 -c -
unzip -qo "$WORK/java_bundle-device.zip" -d "$stage/bundle"

cat > "$stage/keep_symbols.cpp" <<'EOF'
// Referencing loadfunctions() (from ios-tools' symbol_keeper.cpp) keeps every
// class-library native function linked into the framework.
extern "C" void loadfunctions(void);
extern "C" __attribute__((visibility("default"))) void cs3_openjdk_keep_symbols(void) { loadfunctions(); }
EOF

# Builds $stage/<platform>/OpenJDKRuntime.framework from build_openjdk.sh's output for it.
package() {
  local platform=$1 conf=$2 sdk=$3 target=$4 plist_platform=$5 out=$6
  local fw="$stage/$platform/OpenJDKRuntime.framework"
  mkdir -p "$fw/Headers" "$fw/lib/extras"
  ditto "$stage/bundle/java_bundle-device" "$fw/lib"

  local logging_classes="$WORK/mobile/build/$conf/jdk/modules/java.logging"
  "$BOOT_JDK/bin/jar" --create --file "$fw/lib/extras/java.logging.jar" \
    -C "$logging_classes" java -C "$logging_classes" sun
  local unsupported_classes="$WORK/mobile/build/$conf/jdk/modules/jdk.unsupported"
  "$BOOT_JDK/bin/jar" --create --file "$fw/lib/extras/jdk.unsupported.jar" \
    -C "$unsupported_classes" sun -C "$unsupported_classes" com

  cp "$out/include/jni.h" "$out/include/ios/jni_md.h" "$fw/Headers/"

  xcrun --sdk "$sdk" clang++ \
    -target "$target" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -dynamiclib \
    -Wl,-all_load \
    "$out/lib/libjvm.a" "$out/lib/libjava.a" "$out/lib/libjimage.a" "$out/lib/libnet.a" \
    "$out/lib/libnio.a" "$out/lib/libverify.a" "$out/lib/libzip.a" "$out/lib/libffi.a" \
    "$stage/keep_symbols.cpp" \
    -Wl,-install_name,@rpath/OpenJDKRuntime.framework/OpenJDKRuntime \
    -lz -lc++ \
    -framework Foundation -framework CoreFoundation -framework Security \
    -o "$fw/OpenJDKRuntime"

  cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>OpenJDKRuntime</string>
  <key>CFBundleIdentifier</key><string>dev.akash.cs3.OpenJDKRuntime</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>OpenJDKRuntime</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>27.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>${plist_platform}</string></array>
  <key>MinimumOSVersion</key><string>${MIN_IOS}</string>
</dict>
</plist>
EOF
  frameworks+=(-framework "$fw")
}

frameworks=()
if [ -d "$WORK/out-device/lib" ]; then
  package device ios-aarch64-zero-release iphoneos "arm64-apple-ios${MIN_IOS}" iPhoneOS "$WORK/out-device"
fi
if [ -d "$WORK/out/lib" ]; then
  package sim iossim-aarch64-zero-release iphonesimulator "arm64-apple-ios${MIN_IOS}-simulator" iPhoneSimulator "$WORK/out"
fi
if [ ${#frameworks[@]} -eq 0 ]; then
  echo "nothing to package: run build_openjdk.sh sim and/or device first" >&2
  exit 1
fi

mkdir -p "$DEST"
rm -rf "$DEST/OpenJDKRuntime.xcframework"
xcodebuild -create-xcframework "${frameworks[@]}" -output "$DEST/OpenJDKRuntime.xcframework" >/dev/null
du -sh "$DEST/OpenJDKRuntime.xcframework"
echo "Packaged $DEST/OpenJDKRuntime.xcframework"
