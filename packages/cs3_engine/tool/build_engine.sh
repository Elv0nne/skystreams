#!/usr/bin/env bash
# Builds the engine (../engine, a Gradle project) and copies its jars into ../assets/engine, where
# the desktop builds and the iOS VM load them from. Android compiles the engine sources in instead.
# Commit the jars it writes: builds use them as they are.
#
# Needs JDK 17 or newer: JAVA_HOME, or on macOS whatever /usr/libexec/java_home finds.
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then
  JAVA_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null || /usr/libexec/java_home -v 17+)"
fi
export JAVA_HOME="${JAVA_HOME:?set JAVA_HOME to a JDK 17 or newer}"

(cd "$PKG/engine" && ./gradlew --console=plain -q :engine-jvm:dist)

dest="$PKG/assets/engine"
rm -rf "$dest"
mkdir -p "$dest"
cp "$PKG/engine/engine-jvm/build/dist/lib/"*.jar "$dest/"
echo "Engine: $(ls "$dest" | wc -l | tr -d ' ') jars, $(du -sh "$dest" | cut -f1) in $dest"
