#!/bin/bash
# Restore pinned sources and tools independently of compiler output reuse.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MADEIRA="$ROOT/testrepos/Madeira"
# Resolve the separately installed Metal compiler before LLVM/FEX compilation.
xcodebuild -downloadComponent MetalToolchain
xcrun --sdk iphoneos metal --version
python3 "$ROOT/ci/fetch-runtime-inputs.py"

# Use exact gitlink commits. Do not fetch binary test corpora or unrelated modules.
cd "$ROOT"
modules=()
for fork in iridium-fex-ios testrepos/Madeira/FEX; do
    for module in fmt range-v3 rpmalloc unordered_dense vixl xxhash; do
        modules+=("$fork/External/$module")
    done
    modules+=("$fork/Source/Common/cpp-optparse")
done
modules+=(testrepos/Madeira/research/dxmt/include/native/directx)
git submodule update --init --depth 1 -- "${modules[@]}"

# Keep the local allocator change reproducible without changing its upstream gitlink.
allocator="$MADEIRA/FEX/External/rpmalloc"
patch="$ROOT/ci/patches/rpmalloc-host-arena.patch"
if git -C "$allocator" apply --reverse --check "$patch" 2>/dev/null; then
    : # Already applied.
else
    git -C "$allocator" apply --check "$patch"
    git -C "$allocator" apply "$patch"
fi
