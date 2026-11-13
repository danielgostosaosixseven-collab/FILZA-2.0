#!/bin/bash
set -euo pipefail

SOURCE_DIR="${1:?Uso: $0 caminho/para/ThreeOneOSFive/Patches}"
OUTPUT_FILE="${2:?Uso: $0 caminho/para/ThreeOneOSFive/Patches arquivo-de-saida}"

{
  echo '    static let criticalFileHashes: [String: String] = ['
  find "$SOURCE_DIR" -maxdepth 1 -type f \( -name '*.bin' -o -name '*.dat' \) -print0 \
    | sort -z \
    | while IFS= read -r -d '' file; do
        name="$(basename "$file")"
        hash="$(shasum -a 256 "$file" | awk '{print $1}')"
        printf '        "%s": "%s",\n' "$name" "$hash"
      done
  echo '    ]'
} > "$OUTPUT_FILE"

test -s "$OUTPUT_FILE"
cat "$OUTPUT_FILE"
