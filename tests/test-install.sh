#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

echo "Testing installer syntax..."
sh -n "$INSTALL_SH"
echo "Syntax check passed."

echo "Testing installer help output..."
sh "$INSTALL_SH" --help >/dev/null
echo "Help flag passed."
