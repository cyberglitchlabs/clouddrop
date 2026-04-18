#!/usr/bin/env bash
set -euo pipefail

failed=0
for file in "$@"; do
    if ! grep -q 'ENC\[' "$file"; then
        echo "ERROR: $file appears to be unencrypted (no ENC[ found)"
        failed=1
    fi
done

if [[ $failed -eq 1 ]]; then
    echo ""
    echo "Run: sops --encrypt --in-place <file>"
    exit 1
fi
