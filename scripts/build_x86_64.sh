#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/launcher"
DYLIB_DIR="$ROOT_DIR/AntigravityTun"
PROXY_DIR="$ROOT_DIR/tools/mitm_proxy"
OUTPUT_DIR="$ROOT_DIR/build_output"
APP_NAME="AntigravityProxyLauncher"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/Resources/version.txt")"
ARCH="x86_64"

APP_BUILD_DIR="$OUTPUT_DIR/$ARCH"
APP_BUNDLE="$APP_BUILD_DIR/${APP_NAME}.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
DYLIB_BUILD_DIR="$DYLIB_DIR/build_x86_64"
DYLIB_BIN="$DYLIB_BUILD_DIR/Release/libAntigravityTun.dylib"
PROXY_BIN="$PROXY_DIR/mitm_proxy"

DMG_NAME="${APP_NAME}_${VERSION}-macos_x86_64.dmg"
ZIP_NAME="${APP_NAME}_${VERSION}-macos_x86_64.zip"

echo "=== Building ${APP_NAME} v${VERSION} for macOS x86_64 ==="

rm -rf "$APP_BUILD_DIR" "$DYLIB_BUILD_DIR"
rm -f "$OUTPUT_DIR/$DMG_NAME" "$OUTPUT_DIR/$ZIP_NAME" "$PROXY_BIN"
mkdir -p "$OUTPUT_DIR"

# 1. Build the injected dylib for Intel Macs.
echo "[1/5] Building libAntigravityTun.dylib (x86_64)..."
xcodebuild \
  -project "$DYLIB_DIR/AntigravityTun.xcodeproj" \
  -scheme AntigravityTun \
  -configuration Release \
  -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$DYLIB_BUILD_DIR" \
  build

test -f "$DYLIB_BIN"

# 2. Build the Go MITM proxy for Intel Macs.
echo "[2/5] Building Go MITM proxy (amd64)..."
(
  cd "$PROXY_DIR"
  GOOS=darwin GOARCH=amd64 go build -trimpath -o mitm_proxy .
)
test -f "$PROXY_BIN"

# 3. Build the launcher for Intel Macs.
echo "[3/5] Building launcher (x86_64)..."
xcodebuild \
  -project "$PROJECT_DIR/AntigravityProxyLauncher.xcodeproj" \
  -scheme AntigravityProxyLauncher \
  -configuration Release \
  -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR="$APP_BUILD_DIR" \
  build

test -d "$APP_BUNDLE"
test -f "$APP_BIN"

# 4. Replace bundled helper binaries with the x86_64 builds and verify them.
echo "[4/5] Bundling and verifying x86_64 components..."
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$DYLIB_BIN" "$APP_BUNDLE/Contents/Resources/libAntigravityTun.dylib"
cp "$PROXY_BIN" "$APP_BUNDLE/Contents/Resources/mitm_proxy"
if [ -f "$PROXY_DIR/.env" ]; then
  cp "$PROXY_DIR/.env" "$APP_BUNDLE/Contents/Resources/.env"
fi

verify_x86_64() {
  local file="$1"
  local arches
  arches="$(lipo -archs "$file")"
  if [ "$arches" != "x86_64" ]; then
    echo "error: expected x86_64, got '$arches': $file" >&2
    exit 1
  fi
  echo "  OK: $file -> $arches"
}

verify_x86_64 "$APP_BIN"
verify_x86_64 "$APP_BUNDLE/Contents/Resources/libAntigravityTun.dylib"
verify_x86_64 "$APP_BUNDLE/Contents/Resources/mitm_proxy"

# Verify any nested Mach-O dylibs produced with the launcher as well.
for dylib in "$APP_BUNDLE/Contents/MacOS/"*.dylib; do
  [ -e "$dylib" ] || continue
  verify_x86_64 "$dylib"
done

# 5. Package the Intel-only application.
echo "[5/5] Creating DMG and ZIP..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$APP_BUNDLE" \
  -ov \
  -format UDZO \
  "$OUTPUT_DIR/$DMG_NAME"

(
  cd "$OUTPUT_DIR"
  ditto -c -k --keepParent "$ARCH/${APP_NAME}.app" "$ZIP_NAME"
)

cat > "$OUTPUT_DIR/SHA256SUMS-x86_64.txt" <<EOF
$(shasum -a 256 "$OUTPUT_DIR/$DMG_NAME" | awk '{print $1}')  $DMG_NAME
$(shasum -a 256 "$OUTPUT_DIR/$ZIP_NAME" | awk '{print $1}')  $ZIP_NAME
EOF

echo ""
echo "=== Done ==="
echo "  DMG: $OUTPUT_DIR/$DMG_NAME"
echo "  ZIP: $OUTPUT_DIR/$ZIP_NAME"
echo "  Checksums: $OUTPUT_DIR/SHA256SUMS-x86_64.txt"
