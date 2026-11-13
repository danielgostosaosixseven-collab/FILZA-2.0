from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
if shutil.which('xcrun'):
    compiler = ['xcrun', 'swiftc']
elif shutil.which('swiftc'):
    compiler = ['swiftc']
else:
    raise SystemExit('Swift compiler is required; run these checks on macOS/Xcode or a Swift toolchain.')
with tempfile.TemporaryDirectory() as directory:
    executable = Path(directory) / 'file-access-policy-tests'
    subprocess.run(compiler + [
        str(root / 'ThreeOneOSFive/helpers/SupportPolicy.swift'),
        str(root / 'tests/WorseQueryPolicyTests.swift'), '-o', str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)
