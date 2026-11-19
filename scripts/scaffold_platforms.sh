#!/usr/bin/env bash
# Adds the platform runners that are not committed to the repository.
#
# `flutter create` only adds missing files and never overwrites what is already
# tracked, so running this locally or in CI is safe and idempotent.
#
# Android is included even though the CloudStream *host* (the Kotlin side that
# loads a .cs3 with a DexClassLoader) is not in this repository: without the
# runner there is no Android build at all, and the app is perfectly usable there
# with the two JavaScript ecosystems.
#
# Web is deliberately absent. The app reads files with `dart:io`, runs plugins
# through FFI, and plays video through libmpv; a web runner would build nothing
# and promise a browser experience the code cannot deliver.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Generating platform runners"
flutter create \
  --platforms=android,ios,macos,windows,linux \
  --project-name aerostream \
  --org dev.aerostream \
  --description "AeroStream - plugin-driven media client" \
  .

# `flutter create` also drops a counter-app smoke test that references a
# `MyApp` this project does not have. It is generated, not ours: drop it so the
# test suite only ever runs real tests.
rm -f test/widget_test.dart

# Plugins choose their own sources, and a good number of them are still plain
# http. Android and Apple platforms refuse cleartext by default, which would
# turn "this plugin's API is not https" into a confusing playback failure, so
# the generated runners opt in the way CloudStream does. The plugin network
# policy is what actually decides which hosts may be reached.
echo "==> Allowing cleartext for plugin sources"

python3 - <<'PY'
import os
import plistlib
import re

def patch(path, marker, transform):
    if not os.path.exists(path):
        print(f"    skipped {path} (not generated)")
        return
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if marker in text:
        print(f"    already set in {path}")
        return
    patched = transform(text)
    if patched == text:
        print(f"    could not patch {path}; check it by hand")
        return
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(patched)
    print(f"    patched {path}")


def android(text):
    # `usesCleartextTraffic` belongs on <application>; the generated manifest
    # always has exactly one.
    return re.sub(
        r"<application\b",
        '<application android:usesCleartextTraffic="true"',
        text,
        count=1,
    )


patch(
    "android/app/src/main/AndroidManifest.xml",
    "usesCleartextTraffic",
    android,
)


def apple_plist(path):
    """Adds the ATS exception to an Info.plist without reordering it."""
    if not os.path.exists(path):
        print(f"    skipped {path} (not generated)")
        return
    with open(path, "rb") as handle:
        try:
            parsed = plistlib.load(handle)
        except Exception:
            print(f"    could not read {path}; add NSAppTransportSecurity by hand")
            return
    if "NSAppTransportSecurity" in parsed:
        print(f"    already set in {path}")
        return
    parsed["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
    with open(path, "wb") as handle:
        plistlib.dump(parsed, handle)
    print(f"    patched {path}")


apple_plist("ios/Runner/Info.plist")
apple_plist("macos/Runner/Info.plist")
PY

echo "==> Platform runners ready"
