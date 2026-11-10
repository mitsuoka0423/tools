#!/bin/bash
# 公証済みの配布用 .app / zip を作る。
#   archive → exportArchive(Developer ID) → notarytool submit --wait → stapler staple → zip
#
# 前提:
#   - チーム L89Y496GWR の「Developer ID Application」証明書
#   - 公証の認証は次のどちらか
#       - App Store Connect API キー（CI はこちら）: NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER_ID を渡す
#       - notarytool の認証プロファイル "notary" を保存済み
#           xcrun notarytool store-credentials notary --apple-id <id> --team-id L89Y496GWR --password <app用pw>
#
# 使い方:
#   ./scripts/build-notarized.sh              # 公証まで行う
#   SKIP_NOTARIZE=1 ./scripts/build-notarized.sh  # 署名の確認だけ（公証しない。配布には使えない）
#
# 出力: build/export/MitsuTools.app（公証・staple 済み）, build/MitsuTools.zip（配布用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="MitsuTools"
CONFIG="Release"
TEAM="L89Y496GWR"
PROFILE="notary"

BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/MitsuTools.xcarchive"
EXPORT_DIR="$ROOT/build/export"
APP="$EXPORT_DIR/MitsuTools.app"
NOTARIZE_ZIP="$BUILD/MitsuTools-notarize.zip"
DIST_ZIP="$ROOT/build/MitsuTools.zip"

rm -rf "$BUILD" "$EXPORT_DIR" "$DIST_ZIP"
mkdir -p "$BUILD"

# ビルド番号（CFBundleVersion）は git のコミット数から採番する。
# Sparkle は CFBundleVersion で新旧を比べるので、リリースごとに増え続ける必要がある。
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
echo "==> 1/4 archive (CFBundleVersion=$BUILD_NUMBER)"
xcodebuild archive \
  -project "$ROOT/MitsuTools.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | tail -20

echo "==> 2/4 exportArchive (Developer ID)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions-DeveloperID.plist" \
  | tail -20

echo "==> 署名の確認"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Runtime" || true

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "SKIP_NOTARIZE=1 のため公証しません（この .app はほかの Mac では Gatekeeper に止められます）"
  exit 0
fi

echo "==> 3/4 公証（notarytool submit --wait）"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  xcrun notarytool submit "$NOTARIZE_ZIP" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait
else
  xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$PROFILE" --wait
fi

echo "==> 4/4 staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP" || true

# staple 後の .app を配布用 zip にする（公証チケット入り）
ditto -c -k --keepParent "$APP" "$DIST_ZIP"

echo ""
echo "完了: $APP"
echo "配布用: $DIST_ZIP"
