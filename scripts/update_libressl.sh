#!/usr/bin/env bash
#
# update_libressl.sh — Download, vendor, and generate sources.txt for LibreSSL.
#
# Usage:
#   ./scripts/update_libressl.sh [version]
#
# Defaults to 4.1.0 if no version is specified.
# Downloads the release tarball from OpenBSD FTP, extracts the crypto/, ssl/,
# and include/ directories into third_party/libressl/, and generates
# sources.txt by parsing the CMakeLists.txt files.

set -euo pipefail

VERSION="${1:-4.1.0}"
TARBALL="libressl-${VERSION}.tar.gz"
URL="https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/${TARBALL}"
EXTRACTED_DIR="libressl-${VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$PACKAGE_ROOT/third_party/libressl"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

echo "==> Downloading LibreSSL ${VERSION}..."
curl -fSL "$URL" -o "$TMPDIR_BASE/$TARBALL"

echo "==> Extracting..."
tar xzf "$TMPDIR_BASE/$TARBALL" -C "$TMPDIR_BASE"
SRC_ROOT="$TMPDIR_BASE/$EXTRACTED_DIR"

if [[ ! -d "$SRC_ROOT/crypto" || ! -d "$SRC_ROOT/ssl" || ! -d "$SRC_ROOT/include" ]]; then
  echo "Error: Extracted directory does not have expected structure."
  ls -la "$SRC_ROOT"
  exit 1
fi

# ---------------------------------------------------------------------------
# Clean old vendored source and copy fresh
# ---------------------------------------------------------------------------
echo "==> Vendoring into $VENDOR_DIR ..."
rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"

# Copy the three directories we need
cp -R "$SRC_ROOT/crypto"  "$VENDOR_DIR/crypto"
cp -R "$SRC_ROOT/ssl"     "$VENDOR_DIR/ssl"
cp -R "$SRC_ROOT/include" "$VENDOR_DIR/include"

# Copy LICENSE and CMakeLists.txt files (useful for future source extraction)
cp "$SRC_ROOT/COPYING" "$VENDOR_DIR/LICENSE" 2>/dev/null || \
  cp "$SRC_ROOT/LICENSE" "$VENDOR_DIR/LICENSE" 2>/dev/null || \
  echo "WARNING: Could not find LICENSE/COPYING file"

# Store version
echo "$VERSION" > "$VENDOR_DIR/VERSION"

# Keep CMakeLists.txt for reference
cp "$SRC_ROOT/crypto/CMakeLists.txt" "$VENDOR_DIR/crypto/CMakeLists.txt" 2>/dev/null || true
cp "$SRC_ROOT/ssl/CMakeLists.txt"    "$VENDOR_DIR/ssl/CMakeLists.txt"    2>/dev/null || true

# ---------------------------------------------------------------------------
# Generate sources.txt from CMakeLists.txt
#
# LibreSSL's CMakeLists.txt uses set() commands listing .c files.
# We extract all .c filenames, prefix them with crypto/ or ssl/, and verify
# each file exists in the vendored tree. Platform-specific (Windows) files
# that don't exist on disk are automatically excluded.
# ---------------------------------------------------------------------------
echo "==> Generating sources.txt..."

SOURCES_FILE="$VENDOR_DIR/sources.txt"
> "$SOURCES_FILE"

extract_c_files_from_cmake() {
  local cmake_file="$1"
  local prefix="$2"

  # Extract all .c filenames from set() blocks.
  # Handles multi-line set() commands by joining lines and extracting *.c tokens.
  grep -oE '[a-zA-Z0-9_/.-]+\.c' "$cmake_file" | sort -u | while read -r src; do
    local full_path="$VENDOR_DIR/${prefix}/${src}"
    if [[ -f "$full_path" ]]; then
      echo "third_party/libressl/${prefix}/${src}"
    fi
  done
}

# Extract crypto sources
if [[ -f "$VENDOR_DIR/crypto/CMakeLists.txt" ]]; then
  extract_c_files_from_cmake "$VENDOR_DIR/crypto/CMakeLists.txt" "crypto" >> "$SOURCES_FILE"
else
  echo "WARNING: crypto/CMakeLists.txt not found — falling back to find"
  find "$VENDOR_DIR/crypto" -name '*.c' -not -path '*/test/*' -not -path '*CMake*' \
    | sed "s|$PACKAGE_ROOT/||" | sort >> "$SOURCES_FILE"
fi

# Extract ssl sources
if [[ -f "$VENDOR_DIR/ssl/CMakeLists.txt" ]]; then
  extract_c_files_from_cmake "$VENDOR_DIR/ssl/CMakeLists.txt" "ssl" >> "$SOURCES_FILE"
else
  echo "WARNING: ssl/CMakeLists.txt not found — falling back to find"
  find "$VENDOR_DIR/ssl" -name '*.c' -not -path '*/test/*' -not -path '*CMake*' \
    | sed "s|$PACKAGE_ROOT/||" | sort >> "$SOURCES_FILE"
fi

# Sort and deduplicate by path.
sort -u -o "$SOURCES_FILE" "$SOURCES_FILE"

# Remove ssl/ files whose basename already appears under crypto/.
# LibreSSL's ssl/ directory contains copies of files from crypto/bytestring/
# (bs_ber.c, bs_cbb.c, bs_cbs.c) and crypto/ (empty.c). In the CMake build
# these are separate static libraries so duplicates don't collide, but in our
# single-pass CBuilder they cause duplicate symbol errors.
# NOTE: We only drop ssl/ entries that collide with crypto/ — other same-named
# files (e.g. crypto/arch/*/crypto_cpu_caps.c) are genuinely different sources.
awk -F/ '
  /\/crypto\// { crypto_basenames[$NF] = 1; print; next }
  /\/ssl\//    { if (!($NF in crypto_basenames)) print; next }
  { print }
' "$SOURCES_FILE" > "${SOURCES_FILE}.dedup"
mv "${SOURCES_FILE}.dedup" "$SOURCES_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
CRYPTO_COUNT=$(grep -c '^third_party/libressl/crypto/' "$SOURCES_FILE" || echo 0)
SSL_COUNT=$(grep -c '^third_party/libressl/ssl/' "$SOURCES_FILE" || echo 0)
TOTAL_COUNT=$(wc -l < "$SOURCES_FILE" | tr -d ' ')

echo ""
echo "Done! Vendored LibreSSL ${VERSION} into third_party/libressl/"
echo ""
echo "  crypto/ sources: ${CRYPTO_COUNT}"
echo "  ssl/ sources:    ${SSL_COUNT}"
echo "  total sources:   ${TOTAL_COUNT}"
echo ""
echo "  sources.txt:     ${SOURCES_FILE}"
echo "  VERSION:         ${VERSION}"
echo ""
echo "Vendored directory sizes:"
du -sh "$VENDOR_DIR/crypto" "$VENDOR_DIR/ssl" "$VENDOR_DIR/include"
echo ""
echo "Next steps:"
echo "  1. Update hook/build.dart to compile LibreSSL sources"
echo "  2. Apply NATS C compatibility patches (see ssl-vendoring-plan.md)"
echo "  3. Run tests: just test"
