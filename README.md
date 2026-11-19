# Kite tests

Free emulator testing for Kite, an ad-free YouTube app for Android.

This repo holds only built APKs and the test that runs them. Kite's source code lives elsewhere and is
never added here.

## How it works

1. Put a new build in `apks/` as `Kite-<version>.apk` and push it.
2. GitHub Actions boots an Android 14 emulator (`.github/workflows/emulator-test.yml`) and runs
   `tools/ci_test.sh` on the newest APK: install, launch and Home feed, Search, two videos playing,
   folding and unfolding while playing, and the Shorts tab.
3. The run passes or fails. Its summary page lists each check, and the `kite-test` artifact holds
   screenshots and logs.

To test an older build, open the Actions tab, pick "Emulator test", choose Run workflow and enter its path,
for example `apks/Kite-2.9.2.apk`.

The repo is public so the runs cost no Actions minutes.

## Known limit

YouTube often blocks GitHub's test machines with "Sign in to confirm you're not a bot". When that happens the
video checks show a warning instead of a failure, because playback can't be tested from that network. Real
playback still needs a check on a phone.
