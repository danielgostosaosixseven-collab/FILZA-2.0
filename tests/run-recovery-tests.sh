#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PYTEST'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
source=(root/'ThreeOneOSFive/helpers/DevicePatchService.swift').read_text().replace('import Foundation\n','',1)
gate=(root/'ThreeOneOSFive/helpers/AirLiftConnectionCheckGate.swift').read_text().replace('import Foundation\n','',1)
template=(root/'tests/RecoveryRegression.swift').read_text()
(out/'main.swift').write_text(template.replace('// PRODUCTION_SOURCE',gate+'\n'+source))
PYTEST
swiftc "$OUT/main.swift" -o "$OUT/recovery-tests"
"$OUT/recovery-tests"
