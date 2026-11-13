#!/bin/bash
set -euo pipefail

ROOT="${1:?Uso: $0 raiz-do-projeto}"
PATCH_DIR="$ROOT/ThreeOneOSFive/Patches"
PBX="$ROOT/ThreeOneOSFive.xcodeproj/project.pbxproj"

migrate() {
  local original="$1"
  local opaque="$2"
  if [ -f "$PATCH_DIR/$original" ]; then
    mv "$PATCH_DIR/$original" "$PATCH_DIR/$opaque"
  fi
  sed -i "s#${original//./\\.}#${opaque}#g" "$PBX"
}

migrate 'HS-ALTO-FF-NORMAL.3105' 'p01.bin'
migrate 'HS-ALTO-ANTENA-FF-NORMAL.3105' 'p02.bin'
migrate 'HS-PEITO-FF-NORMAL.3105' 'p03.bin'
migrate 'HS-PEITO-ANTENA-FF-NORMAL.3105' 'p04.bin'
migrate 'HS-PESCOCO-FF-NORMAL.3105' 'p05.bin'
migrate 'BALA-MAGICA-ANTENA-FF-NORMAL.3105' 'p06.bin'
migrate 'HS-ALTO-FF-MAX.3105' 'p07.bin'
migrate 'HS-ALTO-ANTENA-FF-MAX.3105' 'p08.bin'
migrate 'HS-PEITO-FF-MAX.3105' 'p09.bin'
migrate 'HS-PEITO-ANTENA-FF-MAX.3105' 'p10.bin'
migrate 'HS-PESCOCO-ALTO-FF-MAX.3105' 'p11.bin'
migrate 'HS-PESCOCO-ANTENA-FF-MAX.3105' 'p12.bin'
migrate 'HS-PESCOCO-BYPASS-AP-FFTH.3105' 'p15.bin'
migrate 'HS-PESCOCO-BYPASS-AP-FFMAX.3105' 'p16.bin'
