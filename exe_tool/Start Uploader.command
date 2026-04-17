#!/bin/bash
# Double-click this file to start the ASC Metadata Uploader.
# It launches ./asc-server from this same folder. No Dart/Flutter
# install is required — the binary is self-contained.
# Close the Terminal window (or press Ctrl+C) to stop the tool.

cd "$(dirname "$0")"

# Safety: strip macOS quarantine off the binary + its assets so newer
# macOS versions don't block launch. No-op if it was already cleared
# (e.g. user ran `xattr -cr ~/Desktop/exe_tool` once after unzipping).
xattr -cr . 2>/dev/null || true

if [ ! -x ./asc-server ]; then
  echo "asc-server not found or not executable in $(pwd)"
  echo "Expected layout:"
  echo "  exe_tool/"
  echo "   ├── asc-server"
  echo "   ├── web/"
  echo "   └── Start Uploader.command   (this file)"
  read -n 1 -s -r -p "Press any key to close."
  exit 1
fi

echo "Starting ASC uploader on http://localhost:3000 ..."
./asc-server
