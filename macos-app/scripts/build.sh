#!/bin/bash
# Build MoleApp.app dari macos-app/Sources/MoleApp/main.swift
# sekaligus membundle seluruh Mole CLI + Go binaries (analyze-go & status-go) ke Contents/Resources/mole-cli/
# Syarat: Xcode Command Line Tools (swiftc) + Go toolchain
# Opsi: ARCH=universal ./macos-app/scripts/build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_APP_DIR/.." && pwd)"

APP_DIR="$MACOS_APP_DIR/build/MoleApp.app"
SRC_FILE="$MACOS_APP_DIR/Sources/MoleApp/main.swift"
# Semua file Swift dikompilasi bersama; main.swift tetap menjadi entry point
SRC_FILES=("$SRC_FILE")
for f in "$MACOS_APP_DIR"/Sources/MoleApp/*.swift; do
    [[ "$f" == "$SRC_FILE" ]] || SRC_FILES+=("$f")
done
PLIST_FILE="$MACOS_APP_DIR/Resources/Info.plist"
CLI_DEST="$APP_DIR/Contents/Resources/mole-cli"

rm -rf "$APP_DIR" # SAFE: removes only the macos-app/build/MoleApp.app staging bundle
mkdir -p "$APP_DIR/Contents/MacOS" "$CLI_DEST/bin"

echo "▶ [1/4] Build Go binaries (analyze-go & status-go)..."
cd "$REPO_ROOT"
if [[ "${ARCH:-}" == "universal" ]]; then
    if [[ ! -x bin/analyze-darwin-arm64 || ! -x bin/status-darwin-arm64 ]]; then
        CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o bin/analyze-darwin-arm64 ./cmd/analyze
        CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o bin/status-darwin-arm64 ./cmd/status
    fi
    if [[ ! -x bin/analyze-darwin-amd64 || ! -x bin/status-darwin-amd64 ]]; then
        CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -o bin/analyze-darwin-amd64 ./cmd/analyze
        CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -o bin/status-darwin-amd64 ./cmd/status
    fi
    lipo -create bin/analyze-darwin-arm64 bin/analyze-darwin-amd64 -output "$CLI_DEST/bin/analyze-go"
    lipo -create bin/status-darwin-arm64 bin/status-darwin-amd64 -output "$CLI_DEST/bin/status-go"
else
    if [[ ! -x bin/analyze-go || ! -x bin/status-go ]]; then
        go build -ldflags="-s -w" -o bin/analyze-go ./cmd/analyze
        go build -ldflags="-s -w" -o bin/status-go ./cmd/status
    fi
    cp bin/analyze-go "$CLI_DEST/bin/analyze-go"
    cp bin/status-go "$CLI_DEST/bin/status-go"
fi
chmod +x "$CLI_DEST/bin/analyze-go" "$CLI_DEST/bin/status-go"

echo "▶ [2/4] Bundle Mole CLI scripts & libraries..."
cp "$REPO_ROOT/mole" "$CLI_DEST/mole"
cp -R "$REPO_ROOT/bin/"*.sh "$CLI_DEST/bin/"
cp -R "$REPO_ROOT/lib" "$CLI_DEST/lib"
chmod +x "$CLI_DEST/mole" "$CLI_DEST/bin/"*.sh

echo "▶ [3/4] Compile Swift MoleApp (Menu Bar Indicator + Dashboard)..."
cd "$MACOS_APP_DIR"
SDK_PATH="$(xcrun --show-sdk-path)"
SWIFTC_BIN="$(xcrun --find swiftc)"
if [[ "${ARCH:-}" == "universal" ]]; then
    "$SWIFTC_BIN" -O -swift-version 5 -sdk "$SDK_PATH" -target arm64-apple-macos13.0 "${SRC_FILES[@]}" -o build/MoleApp-arm64
    "$SWIFTC_BIN" -O -swift-version 5 -sdk "$SDK_PATH" -target x86_64-apple-macos13.0 "${SRC_FILES[@]}" -o build/MoleApp-x86_64
    lipo -create build/MoleApp-arm64 build/MoleApp-x86_64 -output "$APP_DIR/Contents/MacOS/MoleApp"
    rm -f build/MoleApp-arm64 build/MoleApp-x86_64 # SAFE: removes temporary architecture slices inside build/
else
    HOST_ARCH="$(uname -m)"
    "$SWIFTC_BIN" -O -swift-version 5 -sdk "$SDK_PATH" -target "${HOST_ARCH}-apple-macos13.0" "${SRC_FILES[@]}" -o "$APP_DIR/Contents/MacOS/MoleApp"
fi

cp "$PLIST_FILE" "$APP_DIR/Contents/Info.plist"

echo "▶ [4/4] Codesign MoleApp.app (ad-hoc with stable designated identifier)..."
codesign --force --sign - "$CLI_DEST/bin/analyze-go" "$CLI_DEST/bin/status-go"
codesign --force --sign - --identifier id.local.moleapp \
    --requirements '=designated => identifier "id.local.moleapp"' "$APP_DIR"

echo "✅ Selesai: $APP_DIR"
echo "   Pasang:  cp -R \"$APP_DIR\" /Applications/ && open /Applications/MoleApp.app"
