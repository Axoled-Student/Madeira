# Building the iPhone IPA with GitHub Actions

`.github/workflows` builds an **unsigned** `Madeira-unsigned.ipa` on the hosted
`macos-15` runner. No Mac, Apple ID or signing credentials are needed to
compile it. The workflow is adapted from `Build Madeira iPhone package` in
`arjunyerevan95-dot/Madeira`, which targets an older revision of this tree.

## Running it

Actions tab, **Build Madeira iPhone package**, **Run workflow**. When it
finishes, download the `Madeira-iPhone` artifact (kept 30 days).

| Input | Meaning |
|---|---|
| `configuration` | `Debug` (default) or `Release`. `docs/BUILDING.md` records that Release builds have crashed the guest, so Debug is the default. |
| `fex_run`, `llvm_run`, `wine_run`, `i386_run` | Optional. A run ID whose `ios-fex` / `ios-llvm` / `ios-wine` / `ios-i386` artifact to reuse. Left blank, that dependency is built in the same run. |

`Build iOS dependencies` can also be run on its own (`all`, `fex`, `llvm`,
`wine` or `i386`); its artifacts are what the run-ID inputs above refer to. The LLVM
build is cached on the hash of `scripts/ci-build-llvm.sh`, so a rebuild after
an unrelated change skips it.

## What is built

- **FEX**: `FEX/build-ios`, with two patches from `patches/` applied to the
  submodule checkout: `fex-native-diagnostics.patch` keeps the Windows-only
  diagnostics out of the native build, and `fex-native-allocator-guard.patch`
  removes a call in `AllocatorHooks.cpp` to a macro that is undefined when the
  allocator is disabled (always the case on Apple targets).
- **LLVM 15.0.7** for iOS: every library `research/dxmt/src/airconv/meson.build`
  links.
- **Wine unix side**: `libwineserver.a` (bootstrapped from source, since the
  base archive is a git-ignored output), `libntdll_unix.a`, `libwin32u_unix.a`,
  FreeType, and the FFmpeg archives.
- **The 32-bit farm** (`app/Madeira/i386-windows`): `build/wine-i386/build.sh`,
  every i386 Wine module plus DXMT's i386 `d3d9`, `d3d11`, `dxgi`, `d3d10core`
  and `winemetal`. A 32-bit game needs it: without it the app logs
  `PE probe: machine=0x14c (i386, but the bundle has no i386-windows)` and
  aborts in `build_wow64_parameters`.
- **The app**: DXMT (`libdxmt_combined.a`, with the `air_*` shader headers
  generated as DXMT's own meson build does), Madeira Dock (`dockhost.exe`), the
  staged licence copies, then `xcodebuild`.

The Wine PE modules under `app/Madeira/*-windows` and the GnuTLS archives are
the ones committed to the repository; they are not rebuilt.

## Toolchain note

The hosted runners provide Xcode 26.x (the iOS 26.2 SDK on `macos-15`); the
scripts use Xcode 26.3 when the image has it, otherwise the newest 26.x. The
tree also builds with the iOS 27 SDK. `build/ntdll-unix/server_ios.c` reads
`ri_page_wait_time_mach` from `struct rusage_info_v6`, which only the iOS 27 SDK
has, so that read is guarded on `__IPHONE_OS_VERSION_MAX_ALLOWED`: with an older
SDK the `pgw=` column of the `[xp]` log line reads 0.

Workflows are started from the Actions tab, which lists a workflow only once
its file is on the default branch.

## Not covered

- The IPA is unsigned and carries no entitlements. Sign it with your own Apple
  ID in a sideloading tool; `Madeira.entitlements` is in the artifact.
  Development signing provides `get-task-allow`, which StikDebug's JIT needs.
- The Microsoft VC++ runtime DLLs are not bundled (`tools/fetch-vcruntime.md`).
- A successful build establishes that everything compiles, links and packages.
  It does not establish game compatibility or on-device stability.
