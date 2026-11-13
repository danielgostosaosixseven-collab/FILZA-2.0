#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/AirliftFFI/rust-core"
TARGET="aarch64-apple-ios"

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustup >/dev/null 2>&1; then
  echo "Rust/cargo não está instalado. Configure a toolchain Rust antes do build." >&2
  exit 1
fi

rustup target add "$TARGET"
(
  cd "$CORE"
  cargo build --release --target "$TARGET"
)

ARCHIVE="$CORE/target/$TARGET/release/libairlift_ffi.a"
if [[ ! -s "$ARCHIVE" ]]; then
  echo "Archive AirliftFFI não foi produzido: $ARCHIVE" >&2
  exit 1
fi

rm -rf "$ROOT/AirliftFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$ARCHIVE" \
  -headers "$CORE/include" \
  -output "$ROOT/AirliftFFI.xcframework"

[[ -s "$ROOT/AirliftFFI.xcframework/ios-arm64/libairlift_ffi.a" ]]
echo "AirliftFFI.xcframework criado para iOS arm64 (deployment target $IPHONEOS_DEPLOYMENT_TARGET)."
