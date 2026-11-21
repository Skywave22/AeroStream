#!/usr/bin/env bash
# Adds the platform runners that are not committed to the repository.
#
# `flutter create` only adds missing files and never overwrites what is already
# tracked, so running this locally or in CI is safe and idempotent.
#
# Android is included here and then adapted to cs3_engine's host activity. The
# package itself contains the DEX engine; the generated app must supply the
# AppCompat/CloudStream activity that extensions expect to cast their context
# to, rather than Flutter's default FlutterActivity.
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

# CloudStream extensions cast their Activity to CloudStream's MainActivity.
# Flutter's generated FlutterActivity cannot satisfy that contract, so host
# Flutter in a FlutterFragment inside the compatible AppCompatActivity exactly
# as cs3_engine documents. Plugin registration is manual for a fragment host.
mkdir -p android/app/src/main/kotlin/dev/aerostream/aerostream
cat > android/app/src/main/kotlin/dev/aerostream/aerostream/MainActivity.kt <<'KOTLIN'
package dev.aerostream.aerostream

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterEngineConfigurator
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.util.GeneratedPluginRegister

/** A CloudStream-compatible activity that hosts AeroStream's Flutter UI. */
class MainActivity : com.lagradost.cloudstream3.MainActivity(), FlutterEngineConfigurator {
    private var flutterFragment: FlutterFragment? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegister.registerGeneratedPlugins(flutterEngine)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        switchLaunchThemeForNormalTheme()
        super.onCreate(savedInstanceState)
        setContentView(FrameLayout(this).apply { id = FRAGMENT_CONTAINER_ID })
        flutterFragment = supportFragmentManager.findFragmentByTag(TAG_FLUTTER_FRAGMENT) as FlutterFragment?
            ?: FlutterFragment.withNewEngine()
                .shouldAutomaticallyHandleOnBackPressed(true)
                .renderMode(RenderMode.surface)
                .transparencyMode(TransparencyMode.opaque)
                .build<FlutterFragment>()
                .also {
                    supportFragmentManager.beginTransaction()
                        .add(FRAGMENT_CONTAINER_ID, it, TAG_FLUTTER_FRAGMENT)
                        .commit()
                }
    }

    /** Apply Flutter's normal theme after the launch theme, as FlutterActivity does. */
    private fun switchLaunchThemeForNormalTheme() {
        try {
            val metadata = packageManager
                .getActivityInfo(componentName, PackageManager.GET_META_DATA)
                .metaData
            val normalTheme = metadata?.getInt("io.flutter.embedding.android.NormalTheme", -1) ?: -1
            if (normalTheme != -1) setTheme(normalTheme)
        } catch (_: PackageManager.NameNotFoundException) {
        }
    }

    // FlutterFragmentActivity forwards these host callbacks to its fragment.
    override fun onPostResume() {
        super.onPostResume()
        flutterFragment?.onPostResume()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        flutterFragment?.onNewIntent(intent)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        flutterFragment?.onUserLeaveHint()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        flutterFragment?.onTrimMemory(level)
    }

    @Deprecated("Forwarded for extensions that still use startActivityForResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        flutterFragment?.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        flutterFragment?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    companion object {
        private const val TAG_FLUTTER_FRAGMENT = "flutter_fragment"
        private val FRAGMENT_CONTAINER_ID = android.view.View.generateViewId()
    }
}
KOTLIN

# Plugins choose their own sources, and a good number of them are still plain
# http. Android and Apple platforms refuse cleartext by default, which would
# turn "this plugin's API is not https" into a confusing playback failure, so
# the generated runners opt in the way CloudStream does. The plugin network
# policy is what actually decides which hosts may be reached.
echo "==> Allowing cleartext for plugin sources"

python3 - <<'PY'
import glob
import os
import plistlib
import re
import xml.etree.ElementTree as ET

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


def cloudstream_application(text):
    # Stops extension-requested process restarts without killing the app, and
    # installs the CloudStream compatibility context used by cs3_engine. Modern
    # Flutter templates already carry android:name="${applicationName}"; replace
    # that attribute instead of producing invalid XML with the name twice.
    application = re.search(r"<application\b[^>]*>", text, re.DOTALL)
    if application is None:
        return text
    tag = application.group(0)
    name = 'android:name="dev.akash.cs3engine.android.ExtensionHostApplication"'
    if re.search(r'android:name="[^"]*"', tag):
        patched_tag = re.sub(r'android:name="[^"]*"', name, tag, count=1)
    else:
        patched_tag = tag.replace("<application", f"<application {name}", 1)
    return text[:application.start()] + patched_tag + text[application.end():]


def android_appcompat_themes(path):
    """Makes every generated launch/normal theme valid for AppCompatActivity."""
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    patched = re.sub(
        r'(<style\s+name="(?:LaunchTheme|NormalTheme)"\s+parent=")[^"]+("[^>]*>)',
        r'\1Theme.MaterialComponents.DayNight.NoActionBar\2',
        text,
    )
    if patched == text:
        print(f"    already set in {path}")
        return
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(patched)
    print(f"    patched {path}")


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


# libVLC (vlc_player) requires minSdk 29; cs3_engine's CloudStream API is built
# against Android 37. Patch both the Kotlin DSL and legacy groovy templates so
# the app and every Android library resolve against the same SDK surface.
def android_min_sdk(text):
    patched = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 29", text)
    patched = re.sub(r"minSdk\s*=\s*\d+", "minSdk = 29", patched)
    return re.sub(
        r"minSdkVersion\s+(?:flutter\.minSdkVersion|\d+)",
        "minSdkVersion 29",
        patched,
    )


def android_compile_sdk(text):
    patched = re.sub(
        r"compileSdk\s*=\s*(?:flutter\.compileSdkVersion|\d+)",
        "compileSdk = 37",
        text,
    )
    return re.sub(
        r"compileSdkVersion\s+(?:flutter\.compileSdkVersion|\d+)",
        "compileSdkVersion 37",
        patched,
    )


for gradle, min_marker, compile_marker in (
    ("android/app/build.gradle.kts", "minSdk = 29", "compileSdk = 37"),
    ("android/app/build.gradle", "minSdkVersion 29", "compileSdkVersion 37"),
):
    # Independent markers matter when a newer Flutter already defaults to one
    # required level but not the other.
    patch(gradle, min_marker, android_min_sdk)
    patch(gradle, compile_marker, android_compile_sdk)

patch(
    "android/app/src/main/AndroidManifest.xml",
    "usesCleartextTraffic",
    android,
)
patch(
    "android/app/src/main/AndroidManifest.xml",
    "dev.akash.cs3engine.android.ExtensionHostApplication",
    cloudstream_application,
)
patch(
    "android/app/src/main/AndroidManifest.xml",
    ANDROID_PERMISSIONS[0],
    android_permissions,
)
for styles in glob.glob("android/app/src/main/res/values*/styles.xml"):
    android_appcompat_themes(styles)

# Parse the finished file now, before Gradle's expensive manifest-merger step.
# This also rejects duplicate attributes, which caused the first Android build
# after adding ExtensionHostApplication to fail with an opaque merger error.
android_manifest = "android/app/src/main/AndroidManifest.xml"
manifest_root = ET.parse(android_manifest).getroot()
android_namespace = "{http://schemas.android.com/apk/res/android}"
application = manifest_root.find("application")
assert application is not None, "Android manifest has no <application>"
assert application.get(f"{android_namespace}name") == (
    "dev.akash.cs3engine.android.ExtensionHostApplication"
), "Android manifest does not select ExtensionHostApplication"
print(f"    parsed {android_manifest}")


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


# cs3_engine's embedded OpenJDK host requires iOS 15; vlc_player requires
# macOS 12. Raising both the app target and Podfile keeps CocoaPods from
# rejecting the generated runner.
deployment_floor(
    "ios/Runner.xcodeproj/project.pbxproj",
    "IPHONEOS_DEPLOYMENT_TARGET",
    "15.0",
)
deployment_floor(
    "macos/Runner.xcodeproj/project.pbxproj",
    "MACOSX_DEPLOYMENT_TARGET",
    "12.0",
)
pod_platform_floor("ios/Podfile", "ios", "15.0")
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
