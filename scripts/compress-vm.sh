#!/bin/bash
# compress-vm.sh — Run zstdfs compression pass on a mounted macOS VM image.
# Usage: sudo ./compress-vm.sh /Volumes/MyVM [--level 19] [--jobs 8]
set -euo pipefail

VOLUME="${1:?Usage: $0 <volume-path> [--level N] [--jobs N]}"
LEVEL=19
JOBS=8

shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --level) LEVEL="$2"; shift 2 ;;
        --jobs)  JOBS="$2";  shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

ZSTDFS="$(dirname "$0")/../tool/.build/release/zstdfs"

echo "Volume:  $VOLUME"
echo "Level:   $LEVEL"
echo "Jobs:    $JOBS"
echo ""

# Files that must never be compressed with type 200/201:
# - The kext itself (chicken-and-egg)
# - Kernel collections (loaded before any kext)
# - Early boot / firmware
SKIP=(
    "$VOLUME/Library/Extensions/DecmpfsZstd.kext"
    "$VOLUME/System/Library/KernelCollections"
    "$VOLUME/System/Volumes/Preboot"
    "$VOLUME/usr/standalone"
    "$VOLUME/private/var/db/KernelExtensionManagement/KernelCollections"
)

SKIP_ARGS=()
for p in "${SKIP[@]}"; do
    SKIP_ARGS+=(--skip "$p")
done

# Target directories (SSV and Data volume)
TARGETS=(
    "$VOLUME/Library/Apple/usr/libexec/oah"     # Rosetta
    "$VOLUME/usr/lib"                            # system dylibs
    "$VOLUME/usr/libexec"
    "$VOLUME/System/Library/Frameworks"
    "$VOLUME/System/Library/dyld"               # shared cache
    "$VOLUME/System/Library/PrivateFrameworks"
    "$VOLUME/Library/Frameworks"
)

"$ZSTDFS" tree \
    --level "$LEVEL" \
    --jobs  "$JOBS"  \
    --min-size 4096  \
    "${SKIP_ARGS[@]}" \
    "${TARGETS[@]}"
