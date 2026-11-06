#!/bin/bash
# Builds SkyStream's own test extension (packages/cs3_engine/test_extension) into
# test_extension/build/SkyStreamTest.cs3: its code (Kotlin via Gradle, then d8), its compiled resources
# (aapt2) and CloudStream's manifest.json, as a CloudStream extension is laid out.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
tools="$sdk/build-tools/$(ls "$sdk/build-tools" | sort -V | tail -1)"
platform="$sdk/platforms/android-36/android.jar"
ext="$here/test_extension"
work="$ext/build/cs3"

[ -f "$ext/local.properties" ] || echo "sdk.dir=$sdk" > "$ext/local.properties"
(cd "$here/engine" && ./gradlew -q :app-shims:jar)
(cd "$ext" && ./gradlew -q :extension:bundleDebugAar)

rm -rf "$work" && mkdir -p "$work/aar" "$work/pkg"
unzip -q -o "$ext/extension/build/outputs/aar/extension-debug.aar" classes.jar -d "$work/aar"
"$tools/d8" --min-api 24 --lib "$platform" --output "$work/pkg" "$work/aar/classes.jar"
"$tools/aapt2" compile --dir "$ext/extension/src/main/res" -o "$work/res.zip"
"$tools/aapt2" link -I "$platform" --manifest "$ext/cs3/AndroidManifest.xml" --min-sdk-version 24 \
  -o "$work/res.apk" "$work/res.zip"
(cd "$work/pkg" && unzip -q -o ../res.apk resources.arsc 'res/*')
cp "$ext/cs3/manifest.json" "$work/pkg/"
rm -f "$ext/build/SkyStreamTest.cs3"
(cd "$work/pkg" && zip -q -r ../../SkyStreamTest.cs3 .)
# Its pages (sign-in, promotion, check), served beside it by the tests' server.
cp -R "$ext/site/." "$ext/build/"
# The engine's tests read copies: the extension itself, and its resources as newer extensions ship them
# (sparse entries need min-sdk 32; compact entries).
"$tools/aapt2" link -I "$platform" --manifest "$ext/cs3/AndroidManifest.xml" --min-sdk-version 32 \
  --enable-sparse-encoding --enable-compact-entries -o "$work/res-compact.apk" "$work/res.zip"
fixtures="$here/engine/test-fixtures"
mkdir -p "$fixtures"
cp "$ext/build/SkyStreamTest.cs3" "$fixtures/"
unzip -p "$work/res-compact.apk" resources.arsc > "$fixtures/compact.arsc"
echo "$ext/build/SkyStreamTest.cs3"
