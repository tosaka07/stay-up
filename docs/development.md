# 開発

ビルド、テスト、配布物の作成について。
使い方は [README](../README.md) を参照。

## 構成

Swift Package Manager で四つのターゲットを作る。

- **StayUpCore**：リースの値オブジェクト、台帳、設定、永続化、CLI との通信プロトコル
- **StayUpService**：状態機械、電源監視、ヘルパーとの XPC、コントロールソケット
- **StayUpApp**：メニューバーとウィンドウ
- **StayUpHelper**：root で動く LaunchDaemon。`pmset disablesleep` の書き換えだけを担当する

SwiftPM は `.app` バンドルを作れないので、`scripts/build-app.sh` が成果物を配置する。

## ビルド

```sh
# build/StayUp.app を作る
./scripts/build-app.sh

# ~/Applications に入れ、~/.local/bin/stay-up にリンクを張る
./scripts/build-app.sh --release --install

# 配布用。利用可能な Developer ID Application 証明書を自動で選ぶ
./scripts/build-app.sh --release --universal --sign auto
```

`--universal` を付けると arm64 と x86_64 の両方を含める。
付けない場合はホストのアーキテクチャだけを作る。

`--sign auto` は証明書が見つからない環境では終了コード 3 で止まる。
署名後は、アプリと CLI とヘルパーの Team ID が一致することまで検証する。

### 署名がないと何が変わるか

root ヘルパーの登録には Developer ID 署名が要る。
`SMAppService` が未署名のバンドルからの登録を受け付けないためである。

未署名のビルドでもアプリは起動するが、アイドルスリープの抑止だけが働く状態になる。
ふたを閉じるとスリープする。
機能の大半はこの状態でも開発できるが、復元保証のうちヘルパーが関わる経路は確認できない。

## テスト

```sh
swift test
```

### カバレッジの方針

```sh
./scripts/check-logic-coverage.sh
```

根幹のロジックについて、行と関数と分岐リージョンがすべて 100% であることを検査する。
対象は次のものである。

- リースの値オブジェクトと台帳
- 状態機械
- 設定と期間の解析
- 通信プロトコル
- 履歴と状態の永続化
- `pmset` 出力の解析

SwiftUI の表示コードと、XPC やソケットやプロセス監視といった OS 境界のアダプタは対象外とする。
これらは後述の回帰テストで確認する。

境界を対象外にすると、そこに入り込んだ誤りはユニットテストでは見つからない。
実際に `pmset -g` の出力を解析する処理で、区切り文字の取り違えが長く残っていた。
テストが差し替え可能な代役を注入していたため、本物の解析が一度も実行されていなかった。
この経験から、解析のような純粋なロジックは境界から切り出して対象に含めている。

### 実際のアプリを動かす回帰テスト

```sh
./scripts/test-session-toolbar-flow.sh
./scripts/test-cli-ttl-flow.sh
./scripts/test-menu-bar-flow.sh
./scripts/test-global-hotkey-flow.sh
./scripts/test-helper-discovery.sh
./scripts/test-crash-recovery.sh
```

`build/StayUp.app` を起動し、メニューバーの操作や CLI からの要求を実際に流す。

クラッシュ復旧テストは root ヘルパーを実際に動かす。
署名済みのヘルパーが有効になっていない環境では、終了コード 77 でスキップする。

## 配布物を作る

```sh
./scripts/release.sh
```

`release.sh` は次を順に行い、`dist/` に ZIP と SHA-256 を出す。

1. 署名付きのユニバーサルビルド
2. 公証
3. ticket の staple
4. Gatekeeper による評価

事前に、公証用の認証情報をキーチェーンへ保存しておく。

```sh
xcrun notarytool store-credentials "StayUp" \
  --key <AuthKey.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>
```

別名で保存した場合は `--profile` で指定する。
`--skip-build` を付けると、既存の `build/StayUp.app` をそのまま公証へ回す。

公証が Accepted でも、ログに警告が残ることがある。
`release.sh` はその内容を必ず取得して表示する。

途中で問題があれば止まる。
Team ID のない ad-hoc ビルドは終了コード 3、公証が Accepted にならなければ 6、`spctl` が公証済みと認識しなければ 7 を返す。

ZIP そのものには ticket を staple できない。
そのため、staple 済みの `.app` から最終的な ZIP を作り直している。

配布とセキュリティの前提は [`release-security.md`](release-security.md) にまとめた。
