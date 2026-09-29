#!/bin/bash
# Helpers shared by scripts/ci-build-*.sh on a hosted macOS runner. Source this
# file from the repository root; it is not meant to be executed.

# The port was built with Xcode 26.3. Use that when the runner image carries it,
# otherwise the newest Xcode 26.x, otherwise whatever xcode-select points at.
madeira_select_xcode() {
  local want="${MADEIRA_XCODE:-/Applications/Xcode_26.3.app}" pick=
  if [ -d "$want" ]; then
    pick="$want"
  else
    pick="$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)"
  fi
  if [ -n "$pick" ]; then
    export DEVELOPER_DIR="$pick/Contents/Developer"
  else
    echo "warning: no Xcode 26.x found; using $(xcode-select -p)" >&2
  fi
  ls -d /Applications/Xcode*.app 2>/dev/null || true
  xcodebuild -version
}

# llvm-mingw cross toolchain (Dock's x86-64 PE, Wine's PE-target configure).
# The tarball hash is the one pinned in docs/BUILDING.md.
madeira_fetch_llvm_mingw() {
  MADEIRA_MINGW=llvm-mingw-20260421-ucrt-macos-universal
  local dir="toolchains/$MADEIRA_MINGW"
  if [ ! -x "$dir/bin/x86_64-w64-mingw32-clang" ]; then
    mkdir -p toolchains
    curl --fail --location --retry 3 \
      "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$MADEIRA_MINGW.tar.xz" \
      -o "toolchains/$MADEIRA_MINGW.tar.xz"
    echo "bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7  toolchains/$MADEIRA_MINGW.tar.xz" \
      | shasum -a 256 -c -
    tar -xf "toolchains/$MADEIRA_MINGW.tar.xz" -C toolchains
    rm "toolchains/$MADEIRA_MINGW.tar.xz"
  fi
  export MADEIRA_MINGW_BIN="$PWD/$dir/bin"
}
