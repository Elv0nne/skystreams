#!/usr/bin/env bash
# Builds CloudStream's `library` module (GPL-3.0) from upstream source at a pinned commit, with
# SkyStream's patches in ./patches applied, and publishes it into ../m2, the Maven repository both
# the Android build and the engine resolve it from. Commit what it writes there.
#
# Needs JDK 21 and the Android SDK (ANDROID_HOME).
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="${CLOUDSTREAM_COMMIT:-d77c8564653346b1dc70339e8758a0fc76dd2819}"
SRC="$PKG/.build/cloudstream"
if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then
  JAVA_HOME="$(/usr/libexec/java_home -v 21)"
fi
export JAVA_HOME="${JAVA_HOME:?set JAVA_HOME to JDK 21}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/recloudstream/cloudstream
fi
git -C "$SRC" fetch -q --depth 1 origin "$COMMIT"
# An earlier run left its patches applied, the files they add included.
git -C "$SRC" -c advice.detachedHead=false checkout -q -f FETCH_HEAD
git -C "$SRC" clean -q -f -d
for patch in "$PKG"/tool/patches/*.patch; do
  git -C "$SRC" apply "$patch"
done
echo "sdk.dir=$ANDROID_HOME" > "$SRC/local.properties"

(cd "$SRC" && ./gradlew --no-daemon -q :library:publishToMavenLocal -Dmaven.repo.local="$PKG/m2")
find "$PKG/m2/com/lagradost" -name '*.jar' -o -name '*.aar' | sed "s#$PKG/##"
