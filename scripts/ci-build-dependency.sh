#!/bin/bash
# Build the source-pinned native dependencies on a hosted macOS runner, without
# signing or a device. Usage: scripts/ci-build-dependency.sh fex|llvm|wine|i386
set -euo pipefail
cd "$(dirname "$0")/.."
MADEIRA_ROOT="$PWD"
MADEIRA_JOBS="$(sysctl -n hw.ncpu)"
# shellcheck source=scripts/ci-common.sh
source scripts/ci-common.sh
mkdir -p ci-output toolchains

component="${1:?Expected fex, llvm, wine, or i386}"
case "$component" in
  fex)
    madeira_select_xcode
    MADEIRA_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    git submodule update --init --depth 1 FEX
    # Fixes the native iOS build needs. Tolerate a FEX revision that already
    # carries one of them.
    #  - diagnostics: keep the Windows-only diagnostics out of the native build.
    #  - allocator-guard: the no-allocator branch of AllocatorHooks.cpp called a
    #    macro that is only defined in the allocator branch.
    for patch in fex-native-diagnostics fex-native-allocator-guard; do
      if git -C FEX apply --reverse --check "$MADEIRA_ROOT/patches/$patch.patch" 2>/dev/null; then
        echo "FEX already carries $patch.patch"
      else
        git -C FEX apply --check "$MADEIRA_ROOT/patches/$patch.patch"
        git -C FEX apply "$MADEIRA_ROOT/patches/$patch.patch"
      fi
    done
    git -C FEX submodule update --init --depth 1 --jobs 3 \
      External/fmt External/xxhash External/range-v3 External/unordered_dense
    # Options of build/fex-ios/build.sh, plus what a clean hosted runner needs.
    # build/fex-ios/build.sh itself configures only when no cache exists.
    cmake -S FEX -B FEX/build-ios -G Ninja \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
      -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="$MADEIRA_SDK" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_THUNKS=OFF \
      -DBUILD_FEX_LINUX_TESTS=OFF -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF \
      -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=OFF \
      -DENABLE_LTO=OFF -DENABLE_WERROR=OFF -DENABLE_OFFLINE_TELEMETRY=OFF \
      -DTUNE_CPU=none
    # -k 0: keep going after a failure, so one run reports every compile error.
    cmake --build FEX/build-ios --parallel "$MADEIRA_JOBS" \
      --target FEXCore FEXCore_Base JemallocLibs softfloat_3e -- -k 0
    # The archives app/Madeira.xcodeproj links must all be there.
    for lib in FEXCore/Source/libFEXCore.a FEXCore/Source/libFEXCore_Base.a \
               FEXCore/Source/libJemallocLibs.a External/fmt/libfmt.a \
               External/cephes/libcephes_128bit.a \
               External/xxhash/cmake_unofficial/libxxhash.a \
               External/SoftFloat-3e/libsoftfloat_3e.a; do
      test -s "FEX/build-ios/$lib" || { echo "missing FEX/build-ios/$lib" >&2; exit 1; }
    done
    tar -czf ci-output/fex-ios.tar.gz FEX/build-ios
    ;;
  llvm)
    exec bash scripts/ci-build-llvm.sh
    ;;
  wine)
    madeira_select_xcode
    git submodule update --init --depth 1 wine
    [ -d research/freetype ] || git clone --depth 1 --branch VER-2-13-3 \
      https://github.com/freetype/freetype.git research/freetype
    madeira_fetch_llvm_mingw
    MADEIRA_BREW_BISON="$(brew --prefix bison)"
    MADEIRA_BREW_LLVM="$(brew --prefix llvm)"
    export PATH="$MADEIRA_MINGW_BIN:$MADEIRA_BREW_BISON/bin:$MADEIRA_BREW_LLVM/bin:$PATH"

    # The unix-side scripts compile against a configured host tree: config.h and
    # the widl-generated headers in wine/build-macos, and (for dwrite) the same
    # generated headers under wine/build-arm64ec/include.
    mkdir -p wine/build-macos
    (
      cd wine/build-macos
      ../configure --enable-win64 --enable-archs=aarch64,arm64ec --disable-tests --without-x
      make -j"$MADEIRA_JOBS" include/all tools/widl/all tools/winebuild/all
    )
    mkdir -p wine/build-arm64ec
    ln -sfn ../build-macos/include wine/build-arm64ec/include

    bash build/freetype-ios/build.sh
    # GnuTLS: the headers the crypto unixlibs compile against. The four
    # archives are committed (app/Madeira/lib{gmp,nettle,hogweed,gnutls}.a),
    # so keep the committed ones rather than freshly built copies.
    (cd build/gnutls-ios/src && shasum -a 256 -c SHA256SUMS)
    bash build/gnutls-ios/build.sh
    git checkout -- app/Madeira/libgmp.a app/Madeira/libnettle.a \
      app/Madeira/libhogweed.a app/Madeira/libgnutls.a
    # FFmpeg: headers for winegstreamer's unix side, and the four archives the
    # app links.
    bash build/ffmpeg/build.sh

    # Run all three even if one fails, so one run reports every failure.
    wine_failed=0
    for step in wineserver ntdll-unix win32u-unix; do
      bash "build/$step/build.sh" || { echo "build/$step/build.sh failed" >&2; wine_failed=1; }
    done
    [ "$wine_failed" -eq 0 ] || exit 1
    tar -czf ci-output/wine-ios.tar.gz \
      app/Madeira/libwineserver.a app/Madeira/libntdll_unix.a app/Madeira/libwin32u_unix.a \
      app/Madeira/libavformat.a app/Madeira/libavcodec.a \
      app/Madeira/libswresample.a app/Madeira/libavutil.a
    ;;
  i386)
    # The 32-bit Windows farm WoW64 sessions load (app/Madeira/i386-windows):
    # every i386 Wine module, plus DXMT's i386 d3d9/d3d11/dxgi/winemetal. Without
    # it the app logs "PE probe: machine=0x14c (i386, but the bundle has no
    # i386-windows)" and a 32-bit game aborts in build_wow64_parameters.
    madeira_select_xcode
    git submodule update --init --depth 1 wine research/dxmt
    git -C research/dxmt submodule update --init --depth 1 --recursive --jobs 3
    madeira_fetch_llvm_mingw
    MADEIRA_BREW_BISON="$(brew --prefix bison)"   # Wine's configure needs bison 3+
    export PATH="$MADEIRA_MINGW_BIN:$MADEIRA_BREW_BISON/bin:$PATH"
    JOBS="$MADEIRA_JOBS" bash build/wine-i386/build.sh || {
      status=$?
      echo '--- tail of the i386 build log' >&2
      tail -n 120 wine/build-i386/madeira-i386-build.log >&2 || true
      exit "$status"
    }
    tar -czf ci-output/i386-ios.tar.gz app/Madeira/i386-windows
    ;;
  *) echo 'Unknown dependency' >&2; exit 2 ;;
esac
shasum -a 256 ci-output/*.tar.gz > "ci-output/${component}-sha256.txt"
git rev-parse HEAD > "ci-output/${component}-source-commit.txt"
