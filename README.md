# StayUp

ふたを閉じても Mac をスリープさせないための macOS 常駐アプリと CLI。

長時間のビルド・エンコード・エージェントの実行を、ふたを閉じたまま走らせ続けるために作った。
現状の機能とプロダクトコンセプトは [`docs/product-overview.md`](docs/product-overview.md) にまとめている。
設計の詳細は [`docs/spec.md`](docs/spec.md) にある。

## 特徴

- **参照カウント式のリース** — 複数のプロセスが同時に抑止を要求できる。
  片方が終わっても、もう片方が生きている限り解除されない
- **解除し忘れが構造的に起きない** — TTL・PID バインド・グローバル拒否権・
  XPC 接続断の検知という多層で、どんな終わり方をしても `disablesleep` が 0 に戻る
- **汎用の CLI** — 特定のツールの知識を持たない。`acquire` / `renew` / `release` / `run`
  というリース操作の一般語だけで構成する

## 要件

macOS 26 以降。UI を標準コンポーネントだけで組み、Liquid Glass に自動追従させるため
（[spec §4](docs/spec.md#4-全体アーキテクチャ)）。

## ビルド

```sh
# ビルドして build/StayUp.app を作る
./scripts/build-app.sh

# ~/Applications に入れ、~/.local/bin/stay-up にリンクを張る
./scripts/build-app.sh --release --install

# 配布用（利用可能な Developer ID Application 証明書を自動選択）
./scripts/build-app.sh --release --sign auto

# 証明書を明示する場合
./scripts/build-app.sh --release --sign "Developer ID Application: ..."
```

```sh
swift test

# 根幹ロジックの行・関数・分岐リージョンがすべて100%か検査
./scripts/check-logic-coverage.sh
```

`--sign auto` は証明書がない環境では終了コード 3 で停止する。
署名後はアプリ、CLI、ヘルパーの Team ID が一致することまで検証する。

100%ゲートの対象は、リース値オブジェクトと台帳、セッション状態機械、設定、
期間解析、制御プロトコル、履歴・状態の永続化ロジック。
SwiftUIの表示コードと、XPC・`pmset`・ソケット・プロセス監視・POSIXファイル操作などの
OS境界アダプタは対象外とし、下記の実アプリ回帰テストで確認する。

実際のアプリを使う回帰テストは次のコマンドで実行できる。

```sh
./scripts/test-session-toolbar-flow.sh
./scripts/test-cli-ttl-flow.sh
./scripts/test-menu-bar-flow.sh
./scripts/test-crash-recovery.sh
```

クラッシュ復旧テストは root ヘルパーを実際に動かすため、Developer ID 署名済みのヘルパーがない環境では終了コード 77 でスキップする。

## 使い方

### コマンドを包む（推奨）

```sh
stay-up run --owner build -- make release
```

プロセスの生存がそのままリースの生存になるので、**解放漏れが原理的に起きない**。
クラッシュしても `kill -9` されてもリースは消える。

### シェルスクリプトの中で

```sh
stay-up acquire --owner my-pipeline --bind-pid $$ --ttl 2h || true
```

`--bind-pid $$` により、`set -e` で途中終了しても `kill` されてもリースは消える。
`trap` による後始末は要らない。

### ハートビート

開始と終了のイベントは取れるが、プロセスに紐づけられない場合。

```sh
# 開始（冪等）
stay-up acquire --owner my-tool --if-not-exists --ttl 30m \
  --lease-file ./.stay-up-lease --label "long task"

# 進捗のたびに TTL を延ばす
stay-up renew --lease-file ./.stay-up-lease --ttl 30m

# 終了
stay-up release --lease-file ./.stay-up-lease
```

**終了処理が実行されなくても安全**。ハートビートが止まれば TTL で自然に失効するので、
`release` は早く解放するための最適化でしかない。

具体的なツールへの繋ぎ込み方は [spec 付録 A](docs/spec.md#付録-a-利用例) を参照。

### 状態を見る

```sh
stay-up status          # 人間可読
stay-up status --json   # 機械可読（tmux / Starship 向け）
stay-up list
stay-up doctor          # ヘルパー・権限・pmset を診断
```

`awake.sh` のフラグ（`start`, `stop`, `status`, `-t`, `-b`）も互換で受け付ける。

## 設計上の要点

### なぜリースなのか

抑止を要求する主体は 1 つとは限らない。単一のオン/オフで扱うと、
片方の作業が終わっただけで全体が解除される。StayUp は要求を個別に追跡し、
**有効なリースが 1 つ以上ある間だけ抑止する**。所有者は自分の分だけを解放でき、
他人の要求を壊せない。

### 復元をどう保証するか

`pmset disablesleep` はシステム全体のグローバル設定で、設定したプロセスが死んでも
**1 のまま残る**。残留すると、誰にも管理されないままカバンの中で発熱し続ける Mac になる。

多層で防いでいる（[spec §6.2](docs/spec.md#62-復元保証最重要)）。

| 層 | 仕組み | カバーする障害 |
| --- | --- | --- |
| 1 | 正常な解放 | 通常操作 |
| 2 | **XPC 接続断をヘルパーが検知** | アプリのクラッシュ・`SIGKILL` |
| 3 | 終了通知での明示解放 | ログアウト・再起動 |
| 4 | ヘルパー起動時の孤児チェックと、アプリ起動時の所有状態復元 | 電源断・カーネルパニック・復旧前の再起動 |
| 5 | heartbeat ウォッチドッグ | 接続だけ生き残る異常系 |
| 6 | 起動時の自己診断と警告 | 他ツールとの競合 |

### 外部に権限を渡すことへの防御

CLI から状態を書き換えられるということは、「Mac をスリープさせない権限」を外部に渡すということ。
外部クライアントのリースには**必ず TTL が付き**（無期限は対話的な操作にのみ許される）、
バッテリー・熱・総継続時間のグローバル条件は**リースより常に強い**。

`--owner` は自己申告の文字列で、認証ではない。意図しない抑止をユーザーが気づいて
取り消せるようにするための識別であって、悪意ある動作を防ぐ機構ではない。

## 現状の制限

- **ヘルパーの登録には Developer ID 署名が必要**。未署名のままでも起動するが、
  `degraded`（アイドルスリープ抑止のみ）になり、ふたを閉じるとスリープする
- ヘルパー登録後の通常操作では `sudo` を使わない。
  初回登録時は macOS の「ログイン項目と機能拡張」でユーザーが承認する
- コントロールセンター対応は初期リリースの対象外
  （[理由](docs/spec.md#スコープ外とした導線-コントロールセンター)）
- CPU アイドルによる自動解除は未実装（設定項目のみ）
