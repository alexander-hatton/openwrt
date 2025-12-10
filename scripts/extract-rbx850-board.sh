#!/usr/bin/env bash
# Extract RBx850 boarddata from a Netgear .chk image and encode it for ath11k.
# Usage: scripts/extract-rbx850-board.sh [path/to/RBS850-*.chk] [output-board-2.bin]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
IMG="${1:-"$REPO_ROOT/extract/tryagain/RBS850-V7.2.6.21.chk"}"
OUT="${2:-"$REPO_ROOT/board-2.bin"}"
WORK="${WORKDIR:-$(mktemp -d /tmp/rbx850-extract.XXXXXX)}"

BINWALK="${BINWALK:-binwalk}"
UBIREADER="${UBIREADER:-ubireader_extract_files}"
UBIIMG_EXTRACT="${UBIIMG_EXTRACT:-ubireader_extract_images}"
UNSQUASH="${UNSQUASH:-unsquashfs}"
BDENCODER="${BDENCODER:-$REPO_ROOT/qca-swiss-army-knife/tools/scripts/ath11k/ath11k-bdencoder}"
NAMES="${NAMES:-bus=ahb,qmi-board-id=255,variant=Netgear-RBx850;bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=Netgear-RBx850}"


err() {
	echo "error: $*" >&2
	exit 1
}

command -v "$BINWALK" >/dev/null 2>&1 || err "binwalk not found"
command -v "$UBIREADER" >/dev/null 2>&1 || err "ubireader_extract_files not found (install python3-ubi_reader)"
command -v "$UBIIMG_EXTRACT" >/dev/null 2>&1 || err "ubireader_extract_images not found (install python3-ubi_reader)"
command -v "$UNSQUASH" >/dev/null 2>&1 || err "unsquashfs not found (install squashfs-tools)"
[ -x "$BDENCODER" ] || err "ath11k-bdencoder not found at $BDENCODER"
[ -f "$IMG" ] || err "image not found: $IMG"

echo "[*] Working directory: $WORK"

echo "[*] Running binwalk on $IMG"
"$BINWALK" -e "$IMG" -C "$WORK" >/dev/null

EXTRACTED_DIR="$(find "$WORK" -maxdepth 1 -type d -name "_$(basename "$IMG").extracted" | head -n1)"
[ -n "$EXTRACTED_DIR" ] || err "binwalk extraction dir not found"

RAW_UBI="$(find "$EXTRACTED_DIR" -maxdepth 1 -type f -name '*.ubi' | head -n1)"
[ -n "$RAW_UBI" ] || err "no .ubi image found under $EXTRACTED_DIR"

# ubireader wants block-aligned length; binwalk leaves trailing bytes unaligned.
PADDED_UBI="$WORK/padded.ubi"
blk=131072
size=$(stat -c '%s' "$RAW_UBI")
pad=$(( (blk - (size % blk)) % blk ))
cat "$RAW_UBI" >"$PADDED_UBI"
if [ "$pad" -gt 0 ]; then
	dd if=/dev/zero bs=1 count="$pad" >>"$PADDED_UBI" 2>/dev/null
fi
echo "[*] Extracting UBIFS from $RAW_UBI (padded +$pad bytes to $PADDED_UBI)"
"$UBIIMG_EXTRACT" -o "$WORK/ubifs-root" "$PADDED_UBI" >/dev/null

ROOTFS_IMG="$(find "$WORK/ubifs-root" -type f -name '*vol-ubi_rootfs.ubifs' | head -n1)"
[ -n "$ROOTFS_IMG" ] || err "ubi_rootfs volume not found under $WORK/ubifs-root"

echo "[*] Unsquashing $ROOTFS_IMG"
"$UNSQUASH" -d "$WORK/squashfs-root" "$ROOTFS_IMG" >/dev/null || \
	echo "[!] unsquashfs returned non-zero (likely creating device nodes), continuing"

RAW_BDWLAN="$(find "$WORK/squashfs-root" -path '*/lib/firmware/IPQ8074/bdwlan.*' | head -n1)"
[ -n "$RAW_BDWLAN" ] || err "bdwlan file not found under extracted rootfs"

cp "$RAW_BDWLAN" "$WORK/bdwlan.raw"

JSON="$WORK/rbx850.json"
{
	echo "["
	echo "  {"
	echo "    \"board\": ["
	IFS=';' read -ra _names <<<"$NAMES"
	for idx in "${!_names[@]}"; do
		name="${_names[$idx]}"
		sep=","
		if [ "$idx" -eq $(( ${#_names[@]} - 1 )) ]; then
			sep=""
		fi
		cat <<EOF
      {
        "names": ["$name"],
        "data": "$WORK/bdwlan.raw"
      }$sep
EOF
	done
	echo "    ]"
	echo "  }"
	echo "]"
} >"$JSON"

echo "[*] Encoding board-2.bin with ath11k-bdencoder"
"$BDENCODER" -c "$JSON" -o "$WORK/board-2.bin"

cp "$WORK/board-2.bin" "$OUT"
echo "[*] Wrote encoded board file to $OUT"

if [ -f "$REPO_ROOT/board-2.bin" ] && ! cmp -s "$WORK/board-2.bin" "$REPO_ROOT/board-2.bin"; then
	echo "[!] Output differs from existing $REPO_ROOT/board-2.bin"
else
	echo "[*] Output matches existing $REPO_ROOT/board-2.bin"
fi
