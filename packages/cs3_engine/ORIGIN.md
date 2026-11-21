# Vendored origin

This package was vendored without source stripping from:

- project: **SkyStream**
- repository: <https://github.com/akashdh11/skystream>
- path: `packages/cs3_engine`
- commit: `f5523ae07d729b579be30976df8783a0b98c4559`
- vendored into AeroStream: 2026-11-21

The package is licensed under GNU GPL version 3. Its complete license is in
[`LICENSE`](LICENSE). Source for the engine, platform hosts, build tools,
CloudStream compatibility shims and tests is retained in this directory. The
committed JARs, local Maven artifacts and iOS OpenJDK framework are the
corresponding build inputs/artifacts SkyStream distributes with that source;
rebuild instructions are in [`BUILD_INSTRUCTIONS.md`](BUILD_INSTRUCTIONS.md).

AeroStream-specific integration lives outside this package in
`lib/plugins/adapters/cloudstream/`, `scripts/scaffold_platforms.sh`, and the
build workflows. Keep this origin record, the package license and corresponding
source with every redistributed binary.
