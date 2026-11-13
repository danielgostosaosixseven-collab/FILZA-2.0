#!/bin/bash
set -euo pipefail

APP_DIR="${1:?Uso: $0 caminho/para/ThreeOneOSFive.app}"

printf '%s\n' 'static let criticalFileHashes: [String: String] = ['
find "$APP_DIR" -maxdepth 1 -type f \( -name '*.bin' -o -name '*.dat' \) -print0 \
  | sort -z \
  | while IFS= read -r -d '' file; do
      name="$(basename "$file")"
      hash="$(shasum -a 256 "$file" | awk '{print $1}')"
      printf '    "%s": "%s",\n' "$name" "$hash"
    done
printf '%s\n' ']'
