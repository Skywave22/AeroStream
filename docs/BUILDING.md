# Building and downloading

The repository ships Dart sources only. Binaries come from two places: the
`Release builds` workflow, which builds all five targets on runners that have
the toolchains, and your own machine.

## Download a build

Every tagged release has the artifacts attached:

```
AeroStream-<version>-android-arm64-v8a.apk       most phones
AeroStream-<version>-android-armeabi-v7a.apk     older 32-bit devices
AeroStream-<version>-android-x86_64.apk          emulators
AeroStream-<version>-android-universal.apk       all ABIs in one file
AeroStream-<version>-linux-x64.tar.gz            extract, run ./bundle/aerostream
AeroStream-<version>-windows-x64-portable.zip    extract anywhere, run aerostream.exe
AeroStream-<version>-windows-x64-setup.exe       Inno Setup installer
AeroStream-<version>-macos-universal.zip         unzip, drag to Applications
AeroStream-<version>-ios-unsigned.ipa            sideload with your own signing
```

All of them are **unsigned**. Android uses the debug key, the Windows installer
and macOS bundle carry no certificate, and the iOS `.ipa` has to be re-signed by
whatever sideloading tool you use. That is a property of not owning a code
signing identity, not an oversight: see `docs/RELEASING.md`.

Releases are created as **pre-releases**. Nothing in them has been run on a
device by CI.

## Build everything yourself

```bash
./scripts/scaffold_platforms.sh   # adds android/ ios/ macos/ windows/ linux/
flutter build apk --release --split-per-abi
flutter build apk --release
# On each desktop OS, use that OS/architecture's JDK 21 before its build:
dart run packages/cs3_engine/tool/build_runtime.dart --java-home "$JAVA_HOME"
flutter build linux --release     # or windows / macos on that target OS
flutter build ios --release --no-codesign
```

The runtime command uses `jlink` and bundles a trimmed Java image for
CloudStream's desktop sidecar. It must run on the platform and architecture
being packaged; otherwise developer builds fall back to machine Java 17+.
Android executes DEX in-process and iOS carries its committed OpenJDK Zero
framework, so neither uses this step.

Linux needs GTK, libmpv and libVLC headers:

```bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
  liblzma-dev libmpv-dev mpv libvlc-dev vlc
```

Windows needs Visual Studio's "Desktop development with C++" workload; macOS and
iOS need Xcode and CocoaPods.

## The workflow

`.github/workflows/release.yml` runs on a `v*` tag, or manually once the file is
on the default branch (GitHub only offers manual dispatch for workflows that
exist there). Inputs: `publish`, `tag`, `prerelease`.

| Job | Runner | Produces |
| --- | --- | --- |
| `Android APKs` | ubuntu-latest | four APKs |
| `Linux bundle` | ubuntu-latest | tarball |
| `Windows build` | windows-latest | portable zip, installer (best effort) |
| `macOS app` | macos-latest | zipped `.app` |
| `iOS unsigned ipa` | macos-latest | `.ipa` |
| `Publish release` | ubuntu-latest | a GitHub Release when all five succeeded |

Each job tees its build log and raises the useful lines as check-run
annotations on failure, because run logs are not reachable from the development
sandbox. A summary is posted in issue #1 either way.

## Which JavaScript engine, and why it is not `flutter_qjs`

The plugin sandbox needs QuickJS compiled from source on every platform.

`flutter_qjs` 0.3.7 cannot be built today: its FFI binding calls
`Pointer.fromFunction` with an `IntPtr` return, which the AOT compiler rejects,
and its bundled `quickjs.c` trips clang 16's implicit pointer-to-integer check.
Its 0.4.x line instead expects QuickJS as a git submodule that pub does not
fetch. `flutter_qjs_next` (pinned to `v1.5.2` in `pubspec.yaml`) compiles the
engine from source for all five targets and exposes the heap limit and interrupt
timeout this runtime relies on.

That switch is also why CI now has a **Release build (Linux)** job: analyze and
`flutter test` are JIT, so a package that only breaks under AOT passed every
check for months while no binary could be produced. A release-mode build costs a
few minutes and closes that hole.
