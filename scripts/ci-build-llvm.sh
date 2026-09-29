#!/bin/bash
# LLVM 15.0.7 for iOS: the static libraries DXMT's airconv links (the list in
# research/dxmt/src/airconv/meson.build), plus the headers build/dxmt-ios/build.sh
# reads from toolchains/. Kept in its own file because the workflow keys its
# build cache on this file's hash: change the recipe and the cache is rebuilt.
set -euo pipefail
cd "$(dirname "$0")/.."
MADEIRA_ROOT="$PWD"
MADEIRA_JOBS="$(sysctl -n hw.ncpu)"
# shellcheck source=scripts/ci-common.sh
source scripts/ci-common.sh
madeira_select_xcode
mkdir -p ci-output toolchains
MADEIRA_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

git clone --depth 1 --branch llvmorg-15.0.7 \
  https://github.com/llvm/llvm-project.git toolchains/llvm-project
python3 - <<'PY'
from pathlib import Path
p = Path('toolchains/llvm-project/llvm/cmake/modules/AddLLVM.cmake')
s = p.read_text()
old = 'MATCHES "Darwin"'
assert old in s, 'LLVM linker platform condition was not found'
p.write_text(s.replace(old, 'MATCHES "Darwin|iOS"'))
PY

# Host-side table generator for the cross build.
cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-host-build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DLLVM_TARGETS_TO_BUILD= -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF
cmake --build toolchains/llvm-host-build --parallel "$MADEIRA_JOBS" --target llvm-tblgen

cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-ios-build -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="$MADEIRA_SDK" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DLLVM_TABLEGEN="$MADEIRA_ROOT/toolchains/llvm-host-build/bin/llvm-tblgen" \
  -DLLVM_TARGETS_TO_BUILD= -DLLVM_BUILD_UTILS=OFF -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_INCLUDE_TOOLS=OFF -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF

# llvm_deps of research/dxmt/src/airconv/meson.build.
LLVM_TARGETS=(
  LLVMPasses LLVMTarget LLVMObjCARCOpts LLVMCoroutines LLVMipo LLVMInstrumentation
  LLVMVectorize LLVMLinker LLVMIRReader LLVMAsmParser LLVMFrontendOpenMP
  LLVMScalarOpts LLVMInstCombine LLVMAggressiveInstCombine LLVMTransformUtils
  LLVMBitWriter LLVMAnalysis LLVMProfileData LLVMSymbolize LLVMDebugInfoPDB
  LLVMDebugInfoMSF LLVMDebugInfoDWARF LLVMObject LLVMTextAPI LLVMMCParser LLVMMC
  LLVMDebugInfoCodeView LLVMBitReader LLVMCore LLVMRemarks LLVMBitstreamReader
  LLVMBinaryFormat LLVMSupport LLVMDemangle
)
cmake --build toolchains/llvm-ios-build --parallel "$MADEIRA_JOBS" --target "${LLVM_TARGETS[@]}"

# Fail here, not at the app link, if a library the recipe promises is missing.
for target in "${LLVM_TARGETS[@]}"; do
  test -s "toolchains/llvm-ios-build/lib/lib$target.a" || {
    echo "missing toolchains/llvm-ios-build/lib/lib$target.a" >&2
    exit 1
  }
done

tar -czf ci-output/llvm-ios.tar.gz toolchains/llvm-ios-build/lib \
  toolchains/llvm-ios-build/include toolchains/llvm-project/llvm/include
shasum -a 256 ci-output/llvm-ios.tar.gz > ci-output/llvm-sha256.txt
git rev-parse HEAD > ci-output/llvm-source-commit.txt
