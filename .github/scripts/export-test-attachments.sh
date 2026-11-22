#!/usr/bin/env bash
# Exports a result bundle's attachments and renames them from UUIDs to the
# names the tests gave them, such as kb-recording-hold-dark.png.
#
#   export-test-attachments.sh <result bundle> <output directory>
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <result bundle> <output directory>" >&2
    exit 64
fi
bundle=$1
output=$2

if [ ! -d "$bundle" ]; then
    echo "No result bundle at $bundle"
    exit 0
fi
mkdir -p "$output"
xcrun xcresulttool export attachments --path "$bundle" --output-path "$output"

python3 -I - "$output" <<'PY'
import json
import os
import re
import sys

folder = sys.argv[1]
manifest_path = os.path.join(folder, "manifest.json")
if not os.path.exists(manifest_path):
    sys.exit(0)
with open(manifest_path) as file:
    manifest = json.load(file)
taken = set()
for test in manifest:
    for attachment in test.get("attachments", []):
        exported = attachment.get("exportedFileName")
        suggested = attachment.get("suggestedHumanReadableName") or exported
        if not exported or not os.path.exists(os.path.join(folder, exported)):
            continue
        # XCTest appends "_<index>_<UUID>" to the name a test gave.
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(?=\.[^.]+$)", "", suggested)
        # XCTest's own attachments have names like 'Debug description for
        # `"Address" TextField`', and actions/upload-artifact refuses the
        # whole artifact over one quote, colon or similar in a file name.
        name = re.sub(r'["`:<>|*?\\/\x00-\x1f]', "_", name)
        stem, extension = os.path.splitext(name)
        candidate, number = name, 2
        while candidate in taken:
            candidate = f"{stem}-{number}{extension}"
            number += 1
        taken.add(candidate)
        os.rename(os.path.join(folder, exported), os.path.join(folder, candidate))
        attachment["exportedFileName"] = candidate
with open(manifest_path, "w") as file:
    json.dump(manifest, file, indent=2)
print(f"Exported {len(taken)} attachments to {folder}")
PY
