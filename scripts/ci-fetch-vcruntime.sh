#!/bin/bash
# Put Microsoft's Visual C++ runtime DLLs, unmodified, where the app picks them up:
#   x64  the twelve DLLs tools/fetch-vcruntime.md lists -> app/Madeira/x86_64-vcruntime,
#        which the app links over the ARM64EC builtins for 64-bit games;
#   x86  the same set built for 32-bit -> app/Madeira/i386-windows, the 32-bit farm the
#        app links whole into syswow64. A DLL of the same name there (Wine's builtin)
#        is replaced, as winetricks' vcrun does for Wine on x86. Microsoft ships no
#        32-bit vcruntime140_1.dll, so that one is skipped.
# They come from Microsoft's own installers, https://aka.ms/vc14/vc_redist.<arch>.exe.
# Usage: scripts/ci-fetch-vcruntime.sh [x64|x86]. Needs 7zz (7-Zip), which it installs
# with Homebrew when missing.
#
# 7-Zip 26 opens only the small Burn container of an installer, not the attached one
# that holds the payload, so every embedded CAB is carved out by its MSCF header
# and extracted, and the CABs those hold (MSIs and CABs without extensions) in turn.
# The approach follows willfaust/Madeira#58.
set -euo pipefail
cd "$(dirname "$0")/.."

arch="${1:-x64}"
names=(concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids
       vcamp140 vccorlib140 vcomp140 vcruntime140 vcruntime140_1 vcruntime140_threads)
case "$arch" in
  x64) dest=app/Madeira/x86_64-vcruntime; machine=0x8664 ;;
  x86) dest=app/Madeira/i386-windows; machine=0x14c
       names=("${names[@]/vcruntime140_1/}") ;;
  *) echo "Usage: $0 [x64|x86]" >&2; exit 2 ;;
esac
url="${MADEIRA_VC_REDIST_URL:-https://aka.ms/vc14/vc_redist.$arch.exe}"

command -v 7zz >/dev/null || brew install sevenzip
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fL --retry 3 -o "$work/vc_redist.exe" "$url"
mkdir "$work/x"
7zz x -y "$work/vc_redist.exe" -o"$work/x" >/dev/null || true

python3 - "$work/vc_redist.exe" "$work/x" <<'EOF'
import struct, sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
i = 0
while (i := data.find(b'MSCF\0\0\0\0', i)) >= 0:
    size = struct.unpack_from('<I', data, i + 8)[0]
    Path(sys.argv[2], f'carved-{i:x}.cab').write_bytes(data[i:i + size])
    i += 8
EOF

# Each pass opens the CABs the previous one exposed.
for _ in 1 2 3 4; do
  while read -r file; do
    [ "$(head -c 4 "$file")" = MSCF ] || continue
    [ ! -e "$file.x" ] || continue
    7zz x -y "$file" -o"$file.x" >/dev/null || true
  done < <(find "$work/x" -type f ! -path '*.x/*.x/*.x/*.x/*' | sort)
done

# Machine field of the PE header (0x8664 is x86-64) and whether the Authenticode
# signature is still attached.
pe_info() {
  python3 - "$1" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
try:
    assert d[:2] == b'MZ'
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    assert d[pe:pe + 4] == b'PE\0\0'
    machine = struct.unpack_from('<H', d, pe + 4)[0]
    magic = struct.unpack_from('<H', d, pe + 24)[0]
    cert = struct.unpack_from('<II', d, pe + 24 + (112 if magic == 0x20b else 96) + 4 * 8)
    print(hex(machine), 'signed' if cert[1] and cert[0] + cert[1] <= len(d) else 'unsigned')
except (AssertionError, struct.error):
    print('none none')
EOF
}

mkdir -p "$dest"
: > "$work/sums"
for name in "${names[@]}"; do
  [ -n "$name" ] || continue
  found=
  while read -r candidate; do
    [ "$(pe_info "$candidate")" = "$machine signed" ] || continue
    found="$candidate"
    break
  done < <(find "$work/x" -type f \( -iname "*${name}.dll*" -o -iname "*${name}_dll*" \) | sort)
  [ -n "$found" ] || { echo "No signed $machine $name.dll in $url" >&2; exit 1; }
  cp "$found" "$dest/$name.dll"
  (cd "$dest" && shasum -a 256 "$name.dll") >> "$work/sums"
done
mkdir -p ci-output
cp "$work/sums" "ci-output/vcruntime-$arch-sha256.txt"
cat "$work/sums"
echo "Visual C++ $arch runtime: $(wc -l < "$work/sums" | tr -d ' ') DLLs in $dest"
