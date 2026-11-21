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


# `flutter create` puts android.permission.INTERNET in the *debug* and *profile*
# manifests only. A release APK — the one anybody installs — therefore has no
# network permission at all: every request fails with a SocketException, no
# repository loads, no plugin downloads, nothing plays. It reads as "the app is
# broken" on a phone while the same code works on desktop, which has no such
# permission model. Declared here, in `main`, so every build type has it.
ANDROID_PERMISSIONS = (
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.WAKE_LOCK",
)


def android_permissions(text):
    missing = [
        permission
        for permission in ANDROID_PERMISSIONS
        if f'android:name="{permission}"' not in text
    ]
    if not missing:
        return text
    block = "".join(
        f'    <uses-permission android:name="{permission}" />\n'
        for permission in missing
    )
    # Directly above <application>: <uses-permission> is only valid as a direct
    # child of <manifest>, which is where this lands.
    return re.sub(
        r"^(\s*)<application\b",
        block + r"\1<application",
        text,
        count=1,
        flags=re.MULTILINE,
    )


# libVLC (vlc_player) requires minSdk 29; `flutter create` generates a lower
# floor, and the manifest merger fails the Android build with an opaque
# error. Patch both the Kotlin DSL and the legacy groovy template.
def android_min_sdk(text):
    patched = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 29", text)
    patched = re.sub(r"minSdk\s*=\s*\d+", "minSdk = 29", patched)
    patched = re.sub(
        r"minSdkVersion\s+(?:flutter\.minSdkVersion|\d+)",
        "minSdkVersion 29",
        patched,
    )
    return patched

for gradle, marker in (
    ("android/app/build.gradle.kts", "minSdk = 29"),
    ("android/app/build.gradle", "minSdkVersion 29"),
):
    # Marker is the post-patch text, so re-running the scaffolder is a no-op.
    patch(gradle, marker, android_min_sdk)

patch(
    "android/app/src/main/AndroidManifest.xml",
    "usesCleartextTraffic",
    android,
)
patch(
    "android/app/src/main/AndroidManifest.xml",
    ANDROID_PERMISSIONS[0],
    android_permissions,
)


def apple_plist(path):
    """Adds the ATS exception to an Info.plist."""
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


def deployment_floor(path, setting, floor):
    """Raises every Xcode deployment target below floor without lowering any."""
    if not os.path.exists(path):
        print(f"    skipped {path} (not generated)")
        return
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    pattern = re.compile(rf"({setting}\s*=\s*)([0-9.]+)(;)")
    changed = False

    def raise_target(match):
        nonlocal changed
        current = tuple(int(part) for part in match.group(2).split("."))
        minimum = tuple(int(part) for part in floor.split("."))
        if current >= minimum:
            return match.group(0)
        changed = True
        return f"{match.group(1)}{floor}{match.group(3)}"

    patched = pattern.sub(raise_target, text)
    if not changed:
        print(f"    already set in {path}")
        return
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(patched)
    print(f"    patched {path}")


def pod_platform_floor(path, platform, floor):
    """Sets CocoaPods' platform floor, including a commented template line."""
    if not os.path.exists(path):
        print(f"    skipped {path} (not generated)")
        return
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    pattern = re.compile(
        rf"^[ \t]*#?[ \t]*platform[ \t]+:{platform},[ \t]*"
        rf"['\"][0-9.]+['\"][ \t]*$",
        re.MULTILINE,
    )
    line = f"platform :{platform}, '{floor}'"
    match = pattern.search(text)
    if match is not None and match.group(0) == line:
        print(f"    already set in {path}")
        return
    patched = (
        pattern.sub(line, text, count=1)
        if match is not None
        else line + "\n" + text
    )
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(patched)
    print(f"    patched {path}")


def plist_flag(path, key):
    """Enables a boolean entitlement in a generated plist."""
    if not os.path.exists(path):
        print(f"    skipped {path} (not generated)")
        return
    with open(path, "rb") as handle:
        parsed = plistlib.load(handle)
    if parsed.get(key) is True:
        print(f"    already set in {path}")
        return
    parsed[key] = True
    with open(path, "wb") as handle:
        plistlib.dump(parsed, handle)
    print(f"    patched {path}")


# vlc_player's CocoaPods targets require iOS 13 and macOS 12. Raising both the
# app target and Podfile keeps CocoaPods from rejecting the generated runner.
deployment_floor(
    "ios/Runner.xcodeproj/project.pbxproj",
    "IPHONEOS_DEPLOYMENT_TARGET",
    "13.0",
)
deployment_floor(
    "macos/Runner.xcodeproj/project.pbxproj",
    "MACOSX_DEPLOYMENT_TARGET",
    "12.0",
)
pod_platform_floor("ios/Podfile", "ios", "13.0")
pod_platform_floor("macos/Podfile", "osx", "12.0")

apple_plist("ios/Runner/Info.plist")
apple_plist("macos/Runner/Info.plist")
plist_flag(
    "macos/Runner/DebugProfile.entitlements",
    "com.apple.security.network.client",
)
plist_flag(
    "macos/Runner/Release.entitlements",
    "com.apple.security.network.client",
)
PY

echo "==> Platform runners ready"
