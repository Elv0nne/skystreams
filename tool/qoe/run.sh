#!/usr/bin/env bash
# bash tool/qoe/run.sh macos|ios|android NAME ONLY [--profile] [--test=FILE] [--dart-define=...]...
#
# Runs the QoE suite on one device with the scenario servers up for the run, then stops what it started. The output
# goes to build/qoe/NAME.log and the servers' request logs to build/qoe/NAME-server.csv and NAME-server2.csv (the
# second server, on 18082, is the two-source rows' other host). ONLY is a QOE_ONLY list; '' runs the whole suite.
# --profile (macos) runs it in `flutter drive --profile`, for start-up times; --test runs another integration test
# instead of the suite; other arguments go to flutter as they are.
#
#   macos    in the scratch mirror $QOE_MIRROR, refreshed from this tree first. Its bundle id is
#            dev.akash.skystream.cs3mvp, so the owner's own app data (dev.akash.skystream) is never touched.
#   ios      on the one booted simulator.
#   android  boots the $QOE_AVD emulator (SkyStream_SignIn_Phone by default) on its cellular link, because an
#            emulator's virtual Wi-Fi drops connections every 30-60 s, and shuts it down after with its Wi-Fi back
#            on. A television (no telephony) keeps its own network. A device already on adb (the owner's phone
#            over wireless debugging) is never used.
set -euo pipefail

usage() {
  echo 'usage: run.sh macos|ios|android NAME ONLY [--profile] [--test=FILE] [--dart-define=...]...' >&2
  exit 2
}
[ $# -ge 3 ] || usage
platform=$1 name=$2 only=$3
shift 3
profile=false target=integration_test/player/qoe_test.dart
extra=()
for arg in "$@"; do
  case $arg in
    --profile) profile=true ;;
    --test=*) target=${arg#--test=} ;;
    *) extra+=("$arg") ;;
  esac
done

root=$(cd "$(dirname "$0")/../.." && pwd)
log=$root/build/qoe/$name.log
mkdir -p "$root/build/qoe"
[ -f "$root/tool/qoe/media/big4k.mp4" ] || bash "$root/tool/qoe/mkmedia.sh" "$root/tool/qoe/media"
# A server left running from elsewhere would answer in this run's place, and this run's would fail to start unseen.
for port in 18081 18082; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN > /dev/null; then
    echo "port $port is taken: stop what serves it first" >&2
    exit 1
  fi
done

server='' server2='' emulator='' phone=''
finish() {
  if [ -n "$emulator" ]; then
    adb -s "$emulator" shell svc wifi enable || true
    adb -s "$emulator" emu kill || true
  fi
  for pid in $server $server2; do
    kill "$pid" 2> /dev/null || true
  done
}
trap finish EXIT

host=127.0.0.1
case $platform in
  macos)
    : "${QOE_MIRROR:?set QOE_MIRROR to the scratch mirror}"
    mkdir -p "$QOE_MIRROR/macos/Runner/Configs"
    rsync -a --delete --exclude .git --exclude build --exclude .dart_tool --exclude .superpowers \
      --exclude dart-defines.json --exclude tool/qoe/media --exclude macos/Runner/Configs/AppInfo.xcconfig \
      "$root/" "$QOE_MIRROR/"
    sed 's/^PRODUCT_BUNDLE_IDENTIFIER = dev\.akash\.skystream$/PRODUCT_BUNDLE_IDENTIFIER = dev.akash.skystream.cs3mvp/' \
      "$root/macos/Runner/Configs/AppInfo.xcconfig" > "$QOE_MIRROR/macos/Runner/Configs/AppInfo.xcconfig"
    grep -q '^PRODUCT_BUNDLE_IDENTIFIER = dev.akash.skystream.cs3mvp$' \
      "$QOE_MIRROR/macos/Runner/Configs/AppInfo.xcconfig"
    cd "$QOE_MIRROR"
    device=macos
    ;;
  ios)
    device=$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p')
    [ "$(printf '%s\n' "$device" | grep -c .)" = 1 ] || { echo 'boot exactly one simulator first' >&2; exit 1; }
    cd "$root"
    ;;
  android)
    if adb devices | awk 'NR > 1 && $1 ~ /^emulator-/' | grep -q .; then
      echo 'an emulator is already running: one at a time' >&2
      exit 1
    fi
    "${ANDROID_HOME:-$HOME/Library/Android/sdk}/emulator/emulator" -avd "${QOE_AVD:-SkyStream_SignIn_Phone}" \
      -no-snapshot-save > /dev/null 2>&1 &
    for _ in $(seq 90); do
      emulator=$(adb devices | awk 'NR > 1 && $1 ~ /^emulator-/ {print $1}')
      [ -n "$emulator" ] && break
      sleep 2
    done
    [ -n "$emulator" ] || { echo 'the emulator did not come up in 3 minutes' >&2; exit 1; }
    adb -s "$emulator" wait-for-device
    for _ in $(seq 150); do
      [ "$(adb -s "$emulator" shell getprop sys.boot_completed | tr -d '\r')" = 1 ] && break
      sleep 2
    done
    # A television has no telephony and so no cellular link: it keeps the network it has.
    if ! adb -s "$emulator" shell service check phone | grep -q 'not found'; then
      adb -s "$emulator" shell svc wifi disable
      adb -s "$emulator" shell svc data enable
      phone=$emulator
    fi
    cd "$root"
    device=$emulator host=10.0.2.2
    ;;
  *) usage ;;
esac

# The servers start once the device is known. The offline row's server takes a phone emulator off its cellular link
# through adb (QOE_ADB_SERIAL); a television has none to turn off, so it gets no serial and the row reports skipped.
# The second server is the two-source rows' other host: the same media on another port, with its own link and log.
export QOE_ADB_SERIAL=$phone
python3 "$root/tool/qoe/server.py" "$root/tool/qoe/media" 18081 --bind 127.0.0.1 \
  --log "$root/build/qoe/$name-server.csv" > /dev/null 2>&1 &
server=$!
python3 "$root/tool/qoe/server.py" "$root/tool/qoe/media" 18082 --bind 127.0.0.1 \
  --log "$root/build/qoe/$name-server2.csv" > /dev/null 2>&1 &
server2=$!

defines=(--dart-define=QOE_E2E=true "--dart-define=QOE_HOST=$host" "--dart-define=QOE_ONLY=$only")
status=0
if $profile; then
  flutter drive --profile --driver test_driver/integration_test.dart --target "$target" -d "$device" \
    "${defines[@]}" ${extra[@]+"${extra[@]}"} > "$log" 2>&1 || status=$?
else
  flutter test "$target" -d "$device" "${defines[@]}" ${extra[@]+"${extra[@]}"} > "$log" 2>&1 || status=$?
fi
echo "$(grep -c 'QOE {' "$log" || true) QOE lines in build/qoe/$name.log"
tail -1 "$log"
exit $status
