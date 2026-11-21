#!/bin/bash
# Kite emulator smoke test, run by .github/workflows/emulator-test.yml (in Gizziboi/Kite-tests) on a booted emulator.
# Usage: tools/ci_test.sh <apk> <outdir>
# Checks: install, launch + Home, Search, two videos play, fold/unfold while playing, Shorts tab.
# Fails on crashes, ANRs, the app dying, or a video that doesn't play.
APK=$1; OUT=${2:-out}
PKG=app.kite
# What YouTube says when it refuses the test machine (not Kite) for a public video.
BOTWALL="confirm you.re not a bot\|SignInConfirmNotBot\|sign in to confirm\|UNPLAYABLE: .This content isn.t available"
mkdir -p "$OUT"
RES="$OUT/results.txt"; : > "$RES"
FAIL=0

note() { echo "$*" | tee -a "$RES"; }
pass() { note "PASS  $*"; }
fail() { note "FAIL  $*"; FAIL=1; }
warn() { note "WARN  $*"; }
shot() { adb exec-out screencap -p > "$OUT/$1.png" 2>/dev/null; }
alive() { adb shell pidof $PKG >/dev/null 2>&1; }
dump() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb shell cat /sdcard/ui.xml > "$OUT/$1.xml" 2>/dev/null; }

# Tap the first view whose content-desc (or text) equals $1, using the dump named $2.
tap() {
  local xy
  xy=$(python3 - "$OUT/$2.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], errors="ignore").read()
for node in re.findall(r"<node [^>]*>", xml):
    d = re.search(r'content-desc="([^"]*)"', node); t = re.search(r' text="([^"]*)"', node)
    if sys.argv[2] in ((d and d.group(1)), (t and t.group(1))):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        x1, y1, x2, y2 = map(int, b.groups()); print((x1 + x2) // 2, (y1 + y2) // 2); break
PY
)
  [ -n "$xy" ] && adb shell input tap $xy && return 0
  return 1
}

# Crash / ANR / still-alive check after a step.
check() {
  local step=$1
  adb logcat -d -b crash > "$OUT/crash.txt" 2>/dev/null
  if grep -q "Process: $PKG" "$OUT/crash.txt"; then fail "$step: Kite crashed (see crash.txt)"; return 1; fi
  if adb logcat -d 2>/dev/null | grep -q "ANR in $PKG"; then fail "$step: Kite stopped responding (ANR)"; return 1; fi
  dump "$step"
  if grep -q "isn't responding" "$OUT/$step.xml" 2>/dev/null; then
    local who
    who=$(grep -o "text=\"[^\"]*isn't responding\"" "$OUT/$step.xml" | head -1 | sed 's/^text="//; s/"$//')
    if echo "$who" | grep -qi "kite"; then fail "$step: '$who' dialog"; return 1; fi
    # The slow emulator sometimes freezes its own System UI: not Kite's fault. Press Wait and go on.
    warn "$step: the emulator showed '$who' (not Kite); pressed Wait"
    tap "Wait" "$step" || adb shell input keyevent 4
    sleep 2
  fi
  if ! alive; then fail "$step: Kite is no longer running"; return 1; fi
  return 0
}

# Is Kite playing audio right now? (media session PLAYING and an audio player started by Kite)
playing() {
  local uid
  uid=$(adb shell dumpsys package $PKG | grep -m1 -o "userId=[0-9]*" | cut -d= -f2)
  adb shell dumpsys media_session > "$OUT/media_session.txt" 2>/dev/null
  adb shell dumpsys audio > "$OUT/audio.txt" 2>/dev/null
  grep -A40 "package=$PKG" "$OUT/media_session.txt" | grep -q "state=PlaybackState {state=3" &&
    grep "u/pid:$uid/" "$OUT/audio.txt" | grep -q "state:started"
}

# Open a video by link and wait up to $2 seconds for it to play.
video() {
  local id=$1 wait=${2:-60} name="video-$1" t=0
  adb shell am start -a android.intent.action.VIEW -d "https://www.youtube.com/watch?v=$id" -n $PKG/.WatchActivity >/dev/null
  while [ $t -lt $wait ]; do
    sleep 5; t=$((t + 5))
    alive || break
    if playing; then sleep 8; shot "$name"; check "$name" && pass "video $id plays (started within ${t}s)"; return 0; fi
  done
  shot "$name"
  check "$name" || return 1
  # YouTube often refuses datacenter IPs (like GitHub's runners) with "Sign in to confirm you're not a bot",
  # or (since 2026-11-21) with UNPLAYABLE "This content isn't available" for these well-known public videos.
  # That's the test machine's network, not a Kite bug, so it's a warning, not a failure.
  adb shell cat /data/data/$PKG/files/errors.txt 2>/dev/null | grep -qi "$BOTWALL" &&
    { warn "video $id: YouTube blocked this test machine as a bot, so playback couldn't be tested here"; return 0; }
  fail "video $id did not play within ${wait}s (Kite's own error log is in errors.txt)"
  return 1
}

echo "== Kite smoke test: $APK"
adb root >/dev/null 2>&1; sleep 2; adb wait-for-device
adb shell settings put global package_verifier_enable 0 >/dev/null 2>&1
adb shell getprop ro.build.version.release | sed 's/^/Android /' | tee "$OUT/device.txt"

# 1. Install
if adb install -r -g "$APK" > "$OUT/install.txt" 2>&1; then pass "install $(basename "$APK")"
else fail "install: $(tail -1 "$OUT/install.txt")"; exit 1; fi
adb logcat -c; adb logcat -b crash -c 2>/dev/null
adb logcat -v time > "$OUT/logcat.txt" 2>&1 &
LOGCAT=$!

# 2. Launch, Home feed
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 25
shot home
if check home; then
  n=$(grep -o 'text="[^"]\{12,\}"' "$OUT/home.xml" | wc -l)
  if [ "$n" -ge 4 ]; then pass "launch + Home feed ($n titles on screen)"; else warn "Home opened but showed only $n titles (feed may not have loaded)"; fi
fi

# 3. Search (builds before 2.9.3 have no button labels: fall back to the top bar's
#    second-from-right clickable icon, which is Search, left of the avatar)
tap_search() {
  tap "Search" home && return 0
  local xy
  xy=$(python3 - "$OUT/home.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], errors="ignore").read()
icons = []
for node in re.findall(r"<node [^>]*>", xml):
    if 'class="android.widget.ImageView"' in node and 'clickable="true"' in node:
        x1, y1, x2, y2 = map(int, re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node).groups())
        if y2 < 400: icons.append((x1, (x1 + x2) // 2, (y1 + y2) // 2))
icons.sort()
if len(icons) >= 2: print(icons[-2][1], icons[-2][2])
PY
)
  [ -n "$xy" ] && adb shell input tap $xy && return 0
  return 1
}
if tap_search; then
  sleep 3; adb shell input text "lofi%shiphop"; adb shell input keyevent 66; sleep 15
  shot search
  if check search; then
    n=$(grep -o 'text="[^"]\{12,\}"' "$OUT/search.xml" | wc -l)
    if [ "$n" -ge 4 ]; then pass "search ($n results on screen)"; else fail "search showed only $n results"; fi
  fi
  adb shell input keyevent 4; sleep 1; adb shell input keyevent 4; sleep 2
else
  fail "search: couldn't find the Search button"
fi

# 4. Videos: two long-lived public videos (a short one, then a full-length music video)
video jNQXAC9IVRw 60
video dQw4w9WgXcQ 60

# 5. Fold/unfold while playing (cover ~344dp -> inner ~690dp)
adb shell wm size 904x2316; adb shell wm density 420; sleep 6; shot fold-cover
check fold-cover && pass "cover-screen size while playing"
adb shell wm size 1812x2176; adb shell wm density 420; sleep 6; shot fold-inner
check fold-inner && pass "inner-screen size while playing"
adb shell wm size reset; adb shell wm density reset; sleep 3

# 5b. A channel page: header and videos must show (it opened blank on 2.9.2)
adb shell am start -n $PKG/.ChannelActivity --es url "https://www.youtube.com/@YouTube" >/dev/null 2>&1; sleep 15
shot channel
if check channel; then
  n=$(grep -o 'text="[^"]\{12,\}"' "$OUT/channel.xml" | wc -l)
  if [ "$n" -ge 3 ]; then pass "channel page ($n titles on screen)"; else fail "channel page showed only $n titles"; fi
fi
adb shell input keyevent 4; sleep 2

# 6. Shorts tab
adb shell am start -n $PKG/.MainActivity >/dev/null; sleep 3; dump main2
if tap "Shorts" main2; then sleep 12; shot shorts; check shorts && pass "Shorts tab opens"
else warn "couldn't find the Shorts tab"; fi

# Collect Kite's own error log (needs root, google_apis image)
for f in errors.txt crash.txt freeze.txt; do
  adb shell cat /data/data/$PKG/files/$f > "$OUT/kite-$f" 2>/dev/null || true
done
[ -s "$OUT/kite-errors.txt" ] && cp "$OUT/kite-errors.txt" "$OUT/errors.txt"
if grep -qi "$BOTWALL" "$OUT"/kite-*.txt 2>/dev/null; then
  warn "YouTube asked this test machine to prove it's not a bot; playback failures may be the test's network, not Kite"
fi
kill $LOGCAT 2>/dev/null
# Echo the end of Kite's error log into the job log too, so it can be read without downloading the artifact.
if [ -s "$OUT/kite-freeze.txt" ]; then echo "== Kite's freeze log (last 60 lines)"; tail -n 60 "$OUT/kite-freeze.txt" | cut -c1-400; fi
if [ -s "$OUT/kite-errors.txt" ]; then echo "== Kite's error log (last 60 lines)"; tail -n 60 "$OUT/kite-errors.txt" | cut -c1-400; fi

{
  echo "## Kite emulator test: $(basename "$APK")"
  echo; echo '```'; cat "$RES"; echo '```'
  [ -s "$OUT/kite-errors.txt" ] && { echo; echo "<details><summary>Kite's own error log</summary>"; echo; echo '```'; head -c 20000 "$OUT/kite-errors.txt"; echo '```'; echo "</details>"; }
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "== RESULT: $([ $FAIL = 0 ] && echo PASSED || echo FAILED)" | tee -a "$RES"
exit $FAIL
