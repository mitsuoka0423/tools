# 配信リリース

MitsuTools は、Developer ID で署名して Apple の公証を受けた zip を、Cloudflare Pages（https://mitsutools.spleeing.com）から配信します。ほかの Mac でも、Gatekeeper に止められずに開けます。2 回目からは、アプリの Sparkle が自動でアップデートを確認します。

配信は GitHub Actions（リポジトリ直下の `.github/workflows/mitsutools-release.yml`）で行います。`mitsutools-v` で始まるタグを push すると、次の順に自動で進みます。このリポジトリにはほかのツールも入るので、タグにはツール名を付けます。

1. Developer ID で署名してビルドし、Apple の公証を受ける
2. Sparkle の鍵で更新用の zip に署名し、`site/updates/appcast.xml` を作る
3. Cloudflare Pages へデプロイする（ダウンロードページ・最新の zip・appcast）
4. GitHub Release を作り、zip を添付する
5. 新しい appcast を main にコミットする

証明書と鍵は GitHub Secrets から一時的に読み込み、終わったら消します。

## ほかの Mac に入れる

1. https://mitsutools.spleeing.com を開き、「最新版をダウンロード」を押す。
2. zip を開き、MitsuTools.app を「アプリケーション」フォルダへ移して開く。
3. 「システム設定 › プライバシーとセキュリティ › アクセシビリティ」で MitsuTools をオンにする。
4. dotfiles で設定を管理しているなら、`~/.config/mitsutools/config.toml` をリンクする（アプリを開く前でも後でもよい）。

## いつものリリース

1. `MitsuTools.xcodeproj/project.pbxproj` の `MARKETING_VERSION`（2 か所）を上げて、コミットして push する。

   ```sh
   git commit -am "chore(mitsutools): bump version to 1.1"
   git push origin main
   ```

2. 同じ版のタグを付けて push する。タグと `MARKETING_VERSION` が違うと、ワークフローは最初に止まります。

   ```sh
   git tag mitsutools-v1.1
   git push origin mitsutools-v1.1
   ```

3. 終わるまで見守る（公証の待ち時間を含めて 15〜20 分ほど）。

   ```sh
   gh run watch -R mitsuoka0423/tools
   ```

4. 終わったら、ワークフローが main に積んだ appcast のコミットを取り込む。

   ```sh
   git pull
   ```

## はじめに一度だけ行う準備

### Cloudflare Pages

1. Pages プロジェクト `mitsutools` を作る（初回だけ。以後はワークフローがデプロイする）。

   ```sh
   cd MitsuTools
   npx wrangler@3 pages project create mitsutools --production-branch=main
   ```

2. Cloudflare のダッシュボードで、プロジェクト `mitsutools` の「カスタムドメイン」に `mitsutools.spleeing.com` を追加する。

### GitHub Secrets

`mitsuoka0423/tools` の Secrets に、次の 8 つを登録します。値はどれも秘密の情報です。書き出したファイルは、登録したらすぐに消してください。Developer ID・公証・Cloudflare の値は、spleeing の visual-timer に登録したものと同じでかまいません（作り方は visual-timer の docs/RELEASE.md と同じ）。

| Secret | 中身 |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application 証明書（秘密鍵つき .p12）を base64 にしたもの |
| `DEVELOPER_ID_CERT_PASSWORD` | 上の .p12 を書き出したときのパスワード |
| `NOTARY_KEY_P8` | App Store Connect API キー（.p8）の中身 |
| `NOTARY_KEY_ID` | 上の API キーの Key ID |
| `NOTARY_ISSUER_ID` | App Store Connect の Issuer ID |
| `MITSUTOOLS_SPARKLE_ED_PRIVATE_KEY` | MitsuTools 専用の Sparkle EdDSA 秘密鍵 |
| `CLOUDFLARE_API_TOKEN` | Cloudflare Pages を編集できる API トークン |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare のアカウント ID |

```sh
R=mitsuoka0423/tools
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERT_P12_BASE64 -R $R
gh secret set DEVELOPER_ID_CERT_PASSWORD -R $R
gh secret set NOTARY_KEY_P8 -R $R < AuthKey_XXXXXXXXXX.p8
gh secret set NOTARY_KEY_ID -R $R --body XXXXXXXXXX
gh secret set NOTARY_ISSUER_ID -R $R
gh secret set CLOUDFLARE_API_TOKEN -R $R
gh secret set CLOUDFLARE_ACCOUNT_ID -R $R
rm DeveloperID.p12 AuthKey_XXXXXXXXXX.p8
```

### Sparkle の EdDSA 秘密鍵

MitsuTools 専用の鍵が、鍵を作った Mac のキーチェーン（アカウント `mitsutools`）にあります。公開鍵はビルド設定 `SPARKLE_PUBLIC_ED_KEY` に入っています。`generate_keys` は、ビルド後の `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` にあります。

1. 公開鍵がビルド設定の `SPARKLE_PUBLIC_ED_KEY` と同じか確かめる。

   ```sh
   ./bin/generate_keys --account mitsutools -p
   ```

2. 秘密鍵を書き出して登録し、ファイルを消す。

   ```sh
   ./bin/generate_keys --account mitsutools -x sparkle_private_key
   gh secret set MITSUTOOLS_SPARKLE_ED_PRIVATE_KEY -R mitsuoka0423/tools < sparkle_private_key
   rm sparkle_private_key
   ```

鍵をなくしたときは、`generate_keys --account mitsutools` で作り直し、`SPARKLE_PUBLIC_ED_KEY` を書き換えて次の版で切り替えます。Developer ID のチーム（L89Y496GWR）で署名し続けていれば、配信済みのアプリにも更新が届きます（Sparkle は、Apple の署名か EdDSA の鍵のどちらか一方だけが変わった更新を受け付けるため）。チームの変更と鍵の作り直しを、同じ版で行わないでください。

## 手元の Mac から出すとき

CI が使えないときだけ、`./scripts/release.sh` で同じことができます。手元には、Developer ID 証明書、notarytool の認証プロファイル `notary`、Sparkle の秘密鍵（キーチェーン）、wrangler のログイン、`gh` のログインが必要です。このスクリプトはタグを GitHub Release と同時に作るので、CI のリリースは動きません。

署名だけ確かめたいときは、公証を飛ばせます（できた .app はほかの Mac では開けません）。

```sh
SKIP_NOTARIZE=1 ./scripts/build-notarized.sh
```

## 注意

- アクセシビリティの許可は、アプリの署名ごとに記録されます。開発用ビルド（Apple Development）から配信版（Developer ID）に入れ替えたときは、もう一度オンにしてください。
- ログイン項目に開発用ビルドが登録されているときは、配信版を開いてから設定の「ログイン時に開く」を入れ直してください。
