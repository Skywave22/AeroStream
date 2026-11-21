# Releasing

What has to be true before a build leaves this machine, and what this repository
deliberately does not contain.

## What CI checks

`.github/workflows/ci.yml` runs on every push and pull request:

| Step | What it proves |
| --- | --- |
| `dart format --set-exit-if-changed` | the tree is formatted; a failure posts the patch as an issue comment |
| `node tool/js_selftest.mjs` | the JavaScript that ships with the app (host bootstrap, DOM shim, Vega loader) behaves — 44 assertions |
| `flutter analyze --fatal-infos` | no warnings, no infos |
| `flutter test --coverage` | the Dart test suite, with line coverage reported in the build comment |

Coverage is **reported, not enforced**. A hard floor invites tests written to
raise a number; the per-file table in the report is what a reviewer reads.

CI does **not** build release artifacts. A green run means the code analyses
and tests clean on one platform with the runners generated — not that five
native toolchains link.

## Cutting a version

1. Pick the version and write it in `pubspec.yaml`:
   ```yaml
   version: 0.2.0+3      # name+build
   ```
2. Mirror it in `lib/core/app_info.dart` (`appVersion`, `appBuildNumber`).
   `test/core/app_info_test.dart` fails if the two disagree — that test is the
   only reason the About tile cannot show a stale number.
3. Add a section to `CHANGELOG.md`.
4. Run the same three commands CI runs, locally:
   ```bash
   dart format --set-exit-if-changed lib test
   flutter analyze --fatal-infos
   flutter test
   node tool/js_selftest.mjs
   ```
5. Build the targets you intend to ship:
   ```bash
   ./scripts/scaffold_platforms.sh
   flutter build apk --release --split-per-abi
   flutter build ios --release
   flutter build macos --release
   flutter build windows --release
   flutter build linux --release
   ```

## What is not in this repository

* **Signing material.** Keystores, provisioning profiles, certificates and store
  credentials. Android builds need `android/key.properties`; iOS and macOS need
  a team in Xcode.
* **Release automation.** No tagging workflow, no publish step: there is no
  store listing to publish to yet, and a workflow that cannot be exercised is
  worse than a documented manual step.
* **App icons and splash screens.** The generated runners ship Flutter's default
  icon. Replacing it is a design task, not a build task.

## Pre-release checklist

- [ ] `CHANGELOG.md` describes the user-visible change, including limits.
- [ ] `docs/PLUGIN_SPEC.md`'s "Not implemented" table still matches the code.
- [ ] A plugin installed from each ecosystem starts, lists and plays on a real
      device — the test suite uses fixtures, not live hosts.
- [ ] Repository adding works for a shortcode, a full URL and a Vega author.
- [ ] Install → update → rollback leaves one previous version usable.
- [ ] Downloads survive an app restart and play from `file://`.
- [ ] Deleting plugin data does not disturb installs, library or history.
