#!/bin/bash
set -euo pipefail

TARGET="${1:?Uso: $0 AntiCrack.swift bloco-de-hashes.swift}"
BLOCK="${2:?Uso: $0 AntiCrack.swift bloco-de-hashes.swift}"
TEMP="${TARGET}.tmp"

awk -v block_file="$BLOCK" '
  /static let criticalFileHashes: \[String: String\] = \[/ {
    while ((getline line < block_file) > 0) print line
    close(block_file)
    in_block = 1
    next
  }
  in_block && /^    \]/ { in_block = 0; next }
  !in_block { print }
' "$TARGET" > "$TEMP"
mv "$TEMP" "$TARGET"
