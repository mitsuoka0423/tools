#!/bin/bash
# 配信リリースを 1 コマンドで行う（手元の Mac から出すとき用）。
# 通常は mitsutools-v タグの push で GitHub Actions（.github/workflows/mitsutools-release.yml）が同じ処理を行う。
# 手順の正本は docs/RELEASE.md。
#   ビルド → Developer ID 署名 → 公証 → staple → zip → Sparkle(EdDSA) 署名 → appcast 更新
#   → Cloudflare Pages へデプロイ → GitHub Release 作成
#
# 前提:
#   - Developer ID Application 証明書（チーム L89Y496GWR）と notarytool プロファイル "notary"
#   - MitsuTools 専用の Sparkle EdDSA 秘密鍵が Keychain のアカウント "mitsutools" にある
#     （generate_keys --account mitsutools）。または SPARKLE_KEY_FILE に秘密鍵のファイルを渡す（CI はこちら）
#   - generate_appcast（Sparkle の配布物の bin/ にある。SPARKLE_BIN で場所を渡せる）
#   - wrangler（npx 経由）で Cloudflare にログイン済み、Pages プロジェクト mitsutools が作成済み
#   - gh auth login 済み
#
# 使い方:
#   ./scripts/release.sh                 # MARKETING_VERSION から版を決める
#   SKIP_BUILD=1 ./scripts/release.sh    # build/export に公証済み .app がある前提でビルドを飛ばす
#   SKIP_DEPLOY=1 ./scripts/release.sh   # appcast 更新まで（デプロイと Release 作成はしない）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE_URL="${BASE_URL:-https://mitsutools.spleeing.com}"
PBXPROJ="MitsuTools.xcodeproj/project.pbxproj"
VERSION="$(grep -m1 -E 'MARKETING_VERSION = [0-9]' "$PBXPROJ" | sed -E 's/.*MARKETING_VERSION = ([0-9.]+);.*/\1/')"
[ -n "$VERSION" ] || { echo "MARKETING_VERSION を取得できません" >&2; exit 1; }
# このリポジトリにはほかのツールも入るので、タグにツール名を付ける
TAG="mitsutools-v$VERSION"
APP="$ROOT/build/export/MitsuTools.app"
DIST="$ROOT/dist/updates"
ZIP_NAME="MitsuTools-$VERSION.zip"

SPARKLE_BIN="${SPARKLE_BIN:-$(command -v generate_appcast 2>/dev/null || true)}"
[ -n "$SPARKLE_BIN" ] || SPARKLE_BIN="$(ls "$ROOT"/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast 2>/dev/null || true)"
[ -n "$SPARKLE_BIN" ] || SPARKLE_BIN="$(ls /opt/homebrew/Caskroom/sparkle/*/bin/generate_appcast 2>/dev/null | sort -V | tail -1 || true)"

fail() { echo "前提が不足: $1" >&2; exit 1; }
[ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN" ] \
  || fail "generate_appcast が見つからない（Sparkle の配布物の bin/ を SPARKLE_BIN で渡す）"
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
    || fail "Developer ID Application 証明書が見つからない"
fi
if [ "${SKIP_DEPLOY:-0}" != "1" ]; then
  command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || fail "gh 未認証（gh auth login）"
  git rev-parse "$TAG" >/dev/null 2>&1 && fail "タグ $TAG は既にある（MARKETING_VERSION を上げてください）"
fi

echo "==> リリース版: $VERSION ($TAG)"

# --- 1) 公証済み .app ---------------------------------------------------
if [ "${SKIP_BUILD:-0}" = "1" ] && [ -d "$APP" ]; then
  echo "==> ビルド省略（既存 $APP を使用）"
else
  ./scripts/build-notarized.sh
fi
[ -d "$APP" ] || fail "公証済み .app が見つからない: $APP"

# --- 2) zip + appcast（EdDSA 署名）-------------------------------------
rm -rf "$ROOT/dist"
mkdir -p "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP_NAME"
"$SPARKLE_BIN" ${SPARKLE_KEY_FILE:+--ed-key-file "$SPARKLE_KEY_FILE"} --account mitsutools \
  --download-url-prefix "$BASE_URL/downloads/" "$DIST"

mkdir -p site/updates site/downloads
cp "$DIST/appcast.xml" site/updates/appcast.xml
rm -f site/downloads/*.zip
cp "$DIST/$ZIP_NAME" "site/downloads/$ZIP_NAME"
# ダウンロードページから常に最新版を取れるよう、版なしの名前でも置く
cp "$DIST/$ZIP_NAME" "site/downloads/MitsuTools.zip"
echo "==> site/updates/appcast.xml を更新"

[ "${SKIP_DEPLOY:-0}" = "1" ] && { echo "SKIP_DEPLOY=1 のためここで終了"; exit 0; }

# --- 3) Cloudflare Pages へデプロイ ------------------------------------
echo "==> Pages へデプロイ"
npx --yes wrangler@3 pages deploy site --project-name=mitsutools --branch=main

# --- 4) appcast をコミットし、GitHub Release を作る ---------------------
git add site/updates/appcast.xml
git commit -m "chore(mitsutools): release $VERSION appcast"
git push origin main
# タグは Release と同時に作る。先にタグだけ push すると、CI のリリースが動いてしまう
gh release create "$TAG" "$DIST/$ZIP_NAME" --target "$(git rev-parse HEAD)" \
  --title "MitsuTools $VERSION" --generate-notes
git fetch origin tag "$TAG"

echo "完了: $VERSION を配信しました"
