#!/usr/bin/env bash
#
# update_nats.sh — Refresh vendored nats.c sources from a local checkout.
#
# Usage:
#   ./scripts/update_nats.sh /path/to/nats.c
#
# This copies the subset of files needed for compilation into
# third_party/nats_c/, replacing whatever was there before.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-nats.c-checkout>"
  exit 1
fi

NATS_SRC="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$PACKAGE_ROOT/third_party/nats_c"

# Validate source directory
if [[ ! -f "$NATS_SRC/src/nats.h" ]]; then
  echo "Error: $NATS_SRC does not look like a nats.c checkout (src/nats.h not found)."
  exit 1
fi

echo "Vendoring nats.c from: $NATS_SRC"
echo "Into: $VENDOR_DIR"
echo ""

# Clean the existing vendored source
rm -rf "$VENDOR_DIR/src"
mkdir -p "$VENDOR_DIR/src/include"
mkdir -p "$VENDOR_DIR/src/glib"
mkdir -p "$VENDOR_DIR/src/unix"

# --- Copy source files ---

# Core .c and .h files (excludes stan/, win/, adapters/)
cp "$NATS_SRC"/src/*.c "$VENDOR_DIR/src/"
cp "$NATS_SRC"/src/*.h "$VENDOR_DIR/src/"

# glib/ sources and headers
cp "$NATS_SRC"/src/glib/*.c "$VENDOR_DIR/src/glib/"
cp "$NATS_SRC"/src/glib/*.h "$VENDOR_DIR/src/glib/"

# unix/ sources
cp "$NATS_SRC"/src/unix/*.c "$VENDOR_DIR/src/unix/"

# include/ platform headers
cp "$NATS_SRC/src/include/n-unix.h" "$VENDOR_DIR/src/include/"
cp "$NATS_SRC/src/include/n-win.h" "$VENDOR_DIR/src/include/"

# --- version.h ---
# Prefer the pre-generated version.h if it exists; otherwise warn.
if [[ -f "$NATS_SRC/src/version.h" ]]; then
  echo "Copied pre-generated version.h"
elif [[ -f "$NATS_SRC/src/version.h.in" ]]; then
  echo "WARNING: version.h not found, only version.h.in exists."
  echo "  You must manually create version.h from version.h.in"
  echo "  by substituting the version values before building."
fi

# --- LICENSE ---
cp "$NATS_SRC/LICENSE" "$VENDOR_DIR/LICENSE"

# --- VERSION ---
# Extract version from version.h if possible, otherwise prompt
VERSION_HEADER="$VENDOR_DIR/src/version.h"
if [[ -f "$VERSION_HEADER" ]]; then
  MAJOR=$(grep '#define NATS_VERSION_MAJOR' "$VERSION_HEADER" | awk '{print $3}')
  MINOR=$(grep '#define NATS_VERSION_MINOR' "$VERSION_HEADER" | awk '{print $3}')
  PATCH=$(grep '#define NATS_VERSION_PATCH' "$VERSION_HEADER" | awk '{print $3}')
  if [[ -n "$MAJOR" && -n "$MINOR" && -n "$PATCH" ]]; then
    echo "v${MAJOR}.${MINOR}.${PATCH}" > "$VENDOR_DIR/VERSION"
    echo "Updated VERSION to v${MAJOR}.${MINOR}.${PATCH}"
  else
    echo "WARNING: Could not parse version from version.h. Update VERSION manually."
  fi
else
  echo "WARNING: No version.h found. Update third_party/nats_c/VERSION manually."
fi

# --- Summary ---
C_COUNT=$(find "$VENDOR_DIR/src" -name '*.c' | wc -l | tr -d ' ')
H_COUNT=$(find "$VENDOR_DIR/src" -name '*.h' | wc -l | tr -d ' ')
echo ""
echo "Done! Vendored $C_COUNT .c files and $H_COUNT .h files."
echo ""
echo "Next steps:"
echo "  1. Compare the .c file list against _sources in hook/build.dart"
echo "     Check for added or removed files and update the list accordingly."
echo "  2. Regenerate FFI bindings:  dart run ffigen --config ffigen.yaml"
echo "  3. Run tests:  just test"
