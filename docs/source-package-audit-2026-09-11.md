# Source package audit, 11 September 2026

Status: binary release remains blocked. This audit found defects in the saved
source package. It does not approve an IPA or change any license.

## Evidence

Reviewed the source and compiled JIT artifacts from Actions run
[34668967882](https://github.com/intraducine/iridium/actions/runs/34668967882),
commit `5e91d1c9173e6aadd05cf8f9568b45a74b8d370e`.

- Source archive SHA-256:
  `d6765e582c780ab37ec1955efde3974cc7da8f0acbf43eaaecacb447b4ab6f78`.
  It matches the saved checksum file.
- Compiled JIT archive SHA-256:
  `fcaf886f9851fb2a47349fc0237688e18cc3ddddf77e99c0570fcfcbc16947a7`.
  It matches its component manifest.
- Six JIT source/metadata files present in both downloaded artifacts were
  compared byte-for-byte and match. The framework is ARM64. Its dynamic
  dependencies are Apple libraries/frameworks. This does not identify every
  statically linked object or prove operation on a device.

## Cargo source defect and correction

The saved idevice source contains 418 vendored crate versions. The selected
iOS normal/build dependency tree contains 205 distinct package/version pairs.
Build dependencies are included; this is not a list of 205 linked libraries.

Compared all 26,369 paths declared in the vendored Cargo checksum manifests.
The saved source package omitted 157 files:

- Eight Rust source files in the two versions of `cc/src/target`.
- 149 upstream binary fixtures or import archives. These include vcpkg test
  files and Windows import archives, not evidence that Windows libraries are
  linked into the iPhone framework.

The collector pruned every directory named `target` and every file with a
binary extension. That removed actual source and broke the vendor checksum
inventory. It now excludes only root build-output directories. Vendored binary
files are retained only when their bytes match the crate checksum record.
Opaque non-vendor archives remain excluded, and signing-file checks remain.

Repacked the pinned, fully vendored idevice source locally with the corrected
collector: all 418 crate versions and 26,369 declared files passed checksum
comparison, with zero missing or changed files. Regression tests cover nested
source directories, root output exclusion and tampered vendor fixtures.

## Cerbero source defect and correction

The saved Cerbero source bundle has 113,129 entries, including downloaded
dependency sources, but no `.recipe`, `.package` or `.cbc` build input files.
Its `recipes` directory contains only `custom.py`. The launcher and recipe
patches are also absent. Thus it cannot reproduce the media build as supplied.

Reproduced this with the exact pinned Cerbero revision and setuptools 80.9.0.
The upstream source-distribution setup does not include those data directories.
A source manifest now includes recipes, packages, configuration, tools and the
launcher. The pre-compilation packaging check compares every file in those
directories, including nested patches. It fails on the original checkout and
passes with the manifest patch. No media compilation was needed for this test.

## Remaining release work

1. Replace the defective source payloads with corrected packages and verify
   their correspondence to retained component builds. Do not relabel the old
   archive as complete. The saved binaries have not been modified by this audit.
2. Complete notice review for the selected Cargo graph. The six selected
   packages with no standalone license-named file include async-compression,
   compression-codecs, compression-core, ns-keyed-archive, plist-macro and
   plist_ffi. Existing supplemental notices cover the compression packages.
   Check embedded headers and exact upstream notices for the others before
   calling them missing licenses. A Cargo license field alone is not a notice.
   Follow-up: plist's full notice is present in `LICENCE`. Supplemental records
   now preserve the other packages' declarations and plist_ffi's LGPL boundary.
3. Inspect the actual GStreamer static archive, selected plugins, link inputs
   and generated configuration. The pinned FFmpeg recipe declares LGPL-2.1-or-
   later and disables `nonfree` and `version3`; recipe declarations alone do
   not establish what the retained binary contains. Review codec dependencies,
   notices and the materials needed to rebuild/relink the static integration.
4. Finish the ANGLE non-Git input and compiler-runtime review, using the
   compiler-plan checks in the graphics audit and the actual retained binaries.
   Capturing Git repositories does not prove that every generated or downloaded
   input was captured.
5. After app linking, match the final packaged libraries and notices to the
   inventory. Keep the permanent matching source download beside a release.
   No final IPA, signing verification or device test has passed in this audit.

The release blockers remain active. The local packaging fixes do not by
themselves complete the dependency license or final link audit.
