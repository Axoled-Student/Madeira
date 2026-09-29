#!/bin/bash
# Assemble the unsigned Madeira IPA from the prebuilt FEX, LLVM and Wine archives
# (build-inputs/{fex,llvm,wine,i386}, produced by ci-build-dependency.sh).
# MADEIRA_CONFIGURATION selects the Xcode configuration; it defaults to Debug
# because docs/BUILDING.md records that Release builds have crashed the guest.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/ci-common.sh
source scripts/ci-common.sh
madeira_select_xcode
MADEIRA_CONFIGURATION="${MADEIRA_CONFIGURATION:-Debug}"
mkdir -p ci-output

git submodule update --init --depth 1 FEX research/dxmt research/madeira-dock
git -C FEX submodule update --init --depth 1 --jobs 3 \
  External/fmt External/xxhash External/range-v3 External/unordered_dense
git -C research/dxmt submodule update --init --depth 1 --recursive --jobs 3

for component in fex llvm wine i386; do
  MADEIRA_INPUT_ARCHIVE="$(find "build-inputs/$component" -name "$component-ios.tar.gz" -type f)"
  MADEIRA_INPUT_HASH="$(find "build-inputs/$component" -name "$component-sha256.txt" -type f)"
  test -f "$MADEIRA_INPUT_ARCHIVE"
  test -f "$MADEIRA_INPUT_HASH"
  cp "$MADEIRA_INPUT_ARCHIVE" ci-output/
  shasum -a 256 -c "$MADEIRA_INPUT_HASH"
  tar -xzf "ci-output/$component-ios.tar.gz"
  rm "ci-output/$component-ios.tar.gz"
done

# DXMT compiles its Metal support modules and the command library with the Metal
# toolchain, which Xcode 26 ships as a separate download.
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain
fi
# The three airconv support modules, exactly as research/dxmt/src/airconv/meson.build
# generates them (metalir_generator, then xxd -n <name> -i). build/dxmt-ios/build.sh
# produces dxmt_command.h itself.
mkdir -p build/dxmt-ios/shader-headers
for shader in air_msad air_samplepos air_tessellation; do
  xcrun -sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 \
    -c "research/dxmt/src/airconv/shaders/$shader.metal" \
    -o "build/dxmt-ios/shader-headers/$shader.air"
  (cd build/dxmt-ios/shader-headers && xxd -n "$shader" -i "$shader.air" "$shader.h")
done
bash build/dxmt-ios/build.sh
xcrun -sdk iphoneos libtool -static -o app/Madeira/libdxmt_combined.a \
  build/dxmt-ios/obj/*.o toolchains/llvm-ios-build/lib/*.a

# Madeira Dock: the x86-64 dockhost.exe the app starts inside the prefix.
madeira_fetch_llvm_mingw
LLVM_MINGW="$MADEIRA_MINGW_BIN" bash build/madeira-dock/build.sh

# The project declares this folder as a resource but the Microsoft runtime DLLs
# are separately licensed and never committed. Keep the folder present.
mkdir -p app/Madeira/x86_64-vcruntime
cp tools/fetch-vcruntime.md app/Madeira/x86_64-vcruntime/README.md
# The Xcode build fails when the bundled licence copies are missing or stale.
bash build/stage-licenses.sh

# ENABLE_DEBUG_DYLIB=NO keeps the app a single executable (Xcode 16+ otherwise
# splits a Debug build into a stub plus Madeira.debug.dylib).
xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
  -configuration "$MADEIRA_CONFIGURATION" -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/xcode-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  ENABLE_DEBUG_DYLIB=NO

MADEIRA_APP="build/xcode-derived/Build/Products/$MADEIRA_CONFIGURATION-iphoneos/Madeira.app"
test -s "$MADEIRA_APP/Madeira"
for module in xtajit64.dll d3d11.dll winemetal.dll dockhost.exe; do
  test -s "$MADEIRA_APP/arm64ec-windows/$module"
done
test -s "$MADEIRA_APP/d3d12/libmetalirconverter.dylib"
# The 32-bit farm: without i386-windows/ntdll.dll a 32-bit target is never treated
# as one (docs/WOW64.md), and d3d9.dll is what a 32-bit D3D9 game loads.
for module in ntdll.dll kernel32.dll d3d9.dll d3d9-emulated.dll d3d11.dll winemetal.dll; do
  test -s "$MADEIRA_APP/i386-windows/$module"
done
plutil -lint "$MADEIRA_APP/Info.plist"
lipo "$MADEIRA_APP/Madeira" -verify_arch arm64
otool -L "$MADEIRA_APP/Madeira" | tee ci-output/linked-libraries.txt
if grep -E '/Users/|/opt/homebrew/' ci-output/linked-libraries.txt; then
  echo 'Unexpected non-system dynamic library dependency' >&2
  exit 1
fi
mkdir -p build/ipa/Payload
ditto "$MADEIRA_APP" build/ipa/Payload/Madeira.app
(cd build/ipa && zip -qry ../../ci-output/Madeira-unsigned.ipa Payload)
unzip -t ci-output/Madeira-unsigned.ipa | tail -1
shasum -a 256 ci-output/Madeira-unsigned.ipa > ci-output/SHA256SUMS
# What the IPA holds, in the log: the result can be checked without downloading it.
ls -l ci-output/Madeira-unsigned.ipa
cat ci-output/SHA256SUMS
echo "IPA entries: $(unzip -Z1 ci-output/Madeira-unsigned.ipa | wc -l | tr -d ' ')"
unzip -l ci-output/Madeira-unsigned.ipa \
  | grep -E 'Payload/Madeira\.app/(Madeira|Info\.plist|Madeira\.entitlements|arm64ec-windows/(xtajit64\.dll|d3d11\.dll|winemetal\.dll|dockhost\.exe)|aarch64-windows/xtajit\.dll|i386-windows/(ntdll|kernel32|d3d9|d3d9-emulated|winemetal)\.dll|d3d12/libmetalirconverter\.dylib|licenses/LICENSE-MADEIRA-GPL-3\.0\.txt)$' \
  || true
echo "i386-windows entries: $(unzip -Z1 ci-output/Madeira-unsigned.ipa | grep -c 'Payload/Madeira.app/i386-windows/' || true)"
git rev-parse HEAD > ci-output/source-commit.txt
git submodule status > ci-output/submodule-commits.txt
cp app/Madeira/Madeira.entitlements ci-output/
cp tools/fetch-vcruntime.md ci-output/
cat > ci-output/BUILD-NOTES.txt <<EOF
Madeira iPhone build ($MADEIRA_CONFIGURATION configuration)

This IPA is unsigned. Sign it with your own Apple ID using a sideloading tool.
Madeira.entitlements is not embedded in an unsigned build; JIT needs get-task-allow
(a development signature supplies it) and the app also asks for
increased-memory-limit and allow-jit, as listed in that file.
The target is a physical ARM64 iPhone/iPad. JIT must be enabled through the
project's StikDebug workflow before game use.
The package contains the Wine PE modules committed to the repository and
source-built iOS libraries (FEX, Wine unix side, FFmpeg, DXMT, Madeira Dock).
The 32-bit (i386-windows) Wine farm is included, so 32-bit games can start.
Microsoft's optional Visual C++ redistributable DLLs are not bundled; see
fetch-vcruntime.md.
Compilation and archive validation do not establish on-device compatibility.
EOF
